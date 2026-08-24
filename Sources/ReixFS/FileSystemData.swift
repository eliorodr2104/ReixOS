//
//  FileSystemData.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Reading and writing the bytes of a file.
///
/// Both walk block by block through the scratch buffer, because a request may
/// start and end anywhere and a block is the smallest thing a disk will move.
/// A whole-block write that covers its block never reads it first, which is the
/// one optimisation here and the only one worth its lines: it halves the disk
/// traffic of writing a file.
extension FileSystem {

    /// Reads up to `count` bytes from `object` starting at `offset`.
    ///
    /// Answers how many were read, which is short at the end of the file and
    /// zero past it. A short read is not an error and never was: the file
    /// ending is not a failure of the request.
    public mutating func read(
        _    object     : UInt32,
        at   offset     : UInt64,
        into destination: UnsafeMutableRawPointer,
             count      : UInt64
    ) -> (status: FSStatus, bytes: UInt64) {

        guard let record = self.object(object) else { return (.notFound, 0) }
        guard record.kind == .file else { return (.wrongKind, 0) }

        guard offset < record.size else { return (.ok, 0) }

        let wanted = min(count, record.size - offset)

        // One request at a time, for the one case where there is nothing to
        // overlap. Anything longer goes through the pipeline below.
        guard wanted > FSLayout.blockSize - (offset % FSLayout.blockSize),
              device.depth > 1
        else {
            return readOneBlockAtATime(record, at: offset, into: destination, wanted: wanted)
        }

        return pipelined(record, at: offset, into: destination, wanted: wanted)
    }


    /// The simple loop: ask, wait, copy, ask again.
    private mutating func readOneBlockAtATime(
        _    record     : FSObject,
        at   offset     : UInt64,
        into destination: UnsafeMutableRawPointer,
             wanted     : UInt64
    ) -> (status: FSStatus, bytes: UInt64) {

        var moved = UInt64(0)

        while moved < wanted {
            let at     = offset + moved
            let inside = at % FSLayout.blockSize
            let chunk  = min(FSLayout.blockSize - inside, wanted - moved)

            guard let block = record.block(at: at) else { return (.notFound, moved) }
            guard readBlock(block, into: dataBuffer) == .ok else { return (.deviceFailed, moved) }

            destination.advanced(by: Int(moved)).copyMemory(
                from     : dataBuffer.advanced(by: Int(inside)),
                byteCount: Int(chunk)
            )

            moved += chunk
        }

        return (.ok, moved)
    }


    /// Keeps several reads going at once, and copies each one out as it lands.
    ///
    /// The loop above waits for every block before asking for the next, which is
    /// one round trip per block however many the device could have been working
    /// on. This one fills the pipe first and only then waits - so the disk is
    /// asked for block two while it is still fetching block one.
    ///
    /// Reads only. Overlapping *writes* would hand the order they reach the
    /// medium to the device, and that order is the whole of why a power cut here
    /// does not lose a file: no old block becomes free before the new state is
    /// down. There is nothing to gain from it on this machine and a silent way to
    /// lose everything.
    ///
    /// Completions may come back in any order, so what each slot was for is
    /// remembered rather than inferred from when it was asked for.
    private mutating func pipelined(
        _    record     : FSObject,
        at   offset     : UInt64,
        into destination: UnsafeMutableRawPointer,
             wanted     : UInt64
    ) -> (status: FSStatus, bytes: UInt64) {

        let depth = min(device.depth, Self.maximumDepth)

        var where_ = InlineArray<4, UInt64>(repeating: 0)   // byte into destination
        var inside = InlineArray<4, UInt64>(repeating: 0)   // byte into the block
        var chunk  = InlineArray<4, UInt64>(repeating: 0)
        var out    = InlineArray<4, Bool>(repeating: false)

        var asked   = UInt64(0)   // bytes handed to the device
        var moved   = UInt64(0)   // bytes copied out
        var flying  = 0
        var failure : FSStatus? = nil

        // Anything left over from a read that gave up before its requests came
        // back. It has to go *before* this one asks for anything, not after: a
        // stale completion collected later would be attributed to whichever
        // request happens to be using that slot now, and its bytes would land in
        // the middle of a file that has nothing to do with it.
        //
        // Draining at the end of the failing read cannot do this. The only way
        // out of the loop with requests still outstanding is a device that has
        // stopped answering, and a device that will not answer cannot be drained.
        while device.collect() != nil {}

        while moved < wanted {

            // Fill the pipe, as far as the device and the file allow.
            while failure == nil, flying < depth, asked < wanted {

                guard let slot = free(out, depth: depth) else { break }

                let at     = offset + asked
                let within = at % FSLayout.blockSize
                let piece  = min(FSLayout.blockSize - within, wanted - asked)

                guard let block = record.block(at: at) else {
                    failure = .notFound
                    break
                }

                let started = device.begin(
                    sectorsPerBlock,
                    from: UInt64(block) * sectorsPerBlock,
                    slot: slot
                )

                guard started == .ok else {
                    failure = .deviceFailed
                    break
                }

                where_[slot] = asked
                inside[slot] = within
                chunk[slot]  = piece
                out[slot]    = true

                asked  += piece
                flying += 1
            }

            guard flying > 0 else { break }

            guard let done = device.collect() else {
                failure = failure ?? .deviceFailed
                break
            }

            flying -= 1
            out[done.slot] = false

            guard done.status == .ok else {
                failure = failure ?? .deviceFailed
                continue
            }

            destination.advanced(by: Int(where_[done.slot])).copyMemory(
                from     : device.buffer(of: done.slot).advanced(by: Int(inside[done.slot])),
                byteCount: Int(chunk[done.slot])
            )

            moved += chunk[done.slot]
        }

        if let failure, moved < wanted { return (failure, moved) }

        return (.ok, moved)
    }

    /// The widest pipe this loop's fixed arrays can describe.
    ///
    /// `InlineArray`'s length has to be a literal, so the four above are the
    /// bound and this is the name for it. A device that says it can take more is
    /// held to four rather than overrunning them.
    static var maximumDepth: Int { 4 }

    /// A slot nobody is using.
    private func free(
        _ out  : InlineArray<4, Bool>,
          depth: Int
    ) -> Int? {
        for slot in 0..<depth where !out[slot] { return slot }
        return nil
    }


    /// Writes `count` bytes into `object` at `offset`, growing it as needed.
    ///
    /// Growth is by whole blocks and always contiguous with what is already
    /// there when the disk allows it, which is what keeps a file that grows a
    /// little at a time inside one extent.
    ///
    /// `replacing` makes the write the file's whole new contents: everything
    /// past the last byte written is dropped. Without it a short write over a
    /// long file leaves the old tail behind, which is what a file system does
    /// when you seek and write, and is exactly *not* what anybody means by
    /// saying "the file now says this". Both are here because both are wanted,
    /// and the difference is one word rather than a second round trip that
    /// something could happen in the middle of.
    public mutating func write(
        _    object   : UInt32,
        at   offset   : UInt64,
        from source   : UnsafeRawPointer,
             count    : UInt64,
             replacing: Bool = false
    ) -> (status: FSStatus, bytes: UInt64) {

        guard var record = self.object(object) else { return (.notFound, 0) }
        guard record.kind == .file else { return (.wrongKind, 0) }
        guard count > 0 else { return (.ok, 0) }

        let end = offset &+ count
        guard end > offset else { return (.noSpace, 0) }

        // How far this file has ever reached, taken before it grows.
        //
        // The line between bytes that are this file's and bytes that are
        // somebody else's leftovers. A block wholly past this point has never
        // been written by this object, so whatever is in it belonged to the last
        // object to hold those blocks - a deleted file, in another container as
        // easily as this one.
        let held = record.size

        let status = grow(&record, to: end, of: object)
        guard status == .ok else { return (status, 0) }

        // The blocks a growth added below the write itself. Nothing in the loop
        // will touch them and a read of them is coming, because the size is
        // about to say they are inside the file.
        guard zeroUntouched(record, beyond: held, upTo: offset) == .ok else {
            return (.deviceFailed, 0)
        }

        var moved = UInt64(0)

        while moved < count {
            let at     = offset + moved
            let inside = at % FSLayout.blockSize
            let chunk  = min(FSLayout.blockSize - inside, count - moved)

            guard let block = record.block(at: at) else { return (.notFound, moved) }

            // Only fill the buffer first when the write leaves part of the block
            // alone, and what "the rest of it" is depends on whose block it was.
            // One this file has already reached keeps its own bytes. One wholly
            // past where it had reached keeps nothing: reading it would carry the
            // last owner's bytes into this file, and a partial write would then
            // publish them.
            //
            // Which is also one read fewer than reading always, on the commonest
            // write there is: the first one into a new file.
            if chunk != FSLayout.blockSize {
                if at - inside >= held {
                    dataBuffer.initializeMemory(
                        as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize)
                    )

                } else {
                    guard readBlock(block, into: dataBuffer) == .ok else {
                        return (.deviceFailed, moved)
                    }
                }
            }

            dataBuffer.advanced(by: Int(inside)).copyMemory(
                from     : source.advanced(by: Int(moved)),
                byteCount: Int(chunk)
            )

            guard writeBlock(block, from: dataBuffer) == .ok else {
                return (.deviceFailed, moved)
            }

            moved += chunk
        }

        if replacing, end < record.size {
            let cut = shrink(&record, toBytes: end, of: object)
            guard cut == .ok else { return (cut, moved) }

        } else if end > record.size {
            record.size     = end
            record.modified = now

            guard store(record, at: object) == .ok else { return (.deviceFailed, moved) }
        }

        return (.ok, moved)
    }


    /// Cuts an object down to `bytes`, giving back every block past the end.
    ///
    /// The extents are rebuilt rather than edited in place: a run that straddles
    /// the new end is kept as its head and the tail released, and everything
    /// after it goes entirely. Rebuilding is what keeps `extents` honest, which
    /// every walk below depends on.
    ///
    /// Nothing is given back until the shortened record is on the medium. It
    /// used to be the other way round, which left a window - one write wide, or
    /// one power cut wide - in which the record still pointed at blocks the map
    /// already called free, and the next file to ask for space got them. See
    /// `barrier`.
    mutating func shrink(
        _       record: inout FSObject,
        toBytes bytes : UInt64,
        of      index : UInt32
    ) -> FSStatus {

        // Clamped rather than converted. A length past the end of the disk
        // cannot be a length this object keeps, and the conversion would trap
        // rather than say so.
        let wanted = FSLayout.divideUp(bytes, FSLayout.blockSize)
        let keep   = wanted > UInt64(record.blocks)
            ? record.blocks
            : UInt32(wanted)

        guard keep < record.blocks else {
            record.size     = bytes
            record.modified = now
            return store(record, at: index)
        }

        var runs    = InlineArray<8, FSExtent>(repeating: FSExtent())
        var extents = UInt8(0)
        var seen    = UInt32(0)

        // What the cut will give back, worked out now and handed back later.
        // At most one run per extent, so the same eight.
        var freeing = InlineArray<8, FSExtent>(repeating: FSExtent())
        var freed   = 0

        for index in 0..<Int(record.extents) {
            let run = record.runs[index]

            if seen >= keep {
                freeing[freed] = run
                freed += 1

            } else if seen + run.count <= keep {
                runs[Int(extents)] = run
                extents += 1
                seen    += run.count

            } else {
                let head = keep - seen

                runs[Int(extents)] = FSExtent(start: run.start, count: head)
                extents += 1

                freeing[freed] = FSExtent(start: run.start + head, count: run.count - head)
                freed += 1

                seen = keep
            }
        }

        let given = record.blocks - keep

        record.runs     = runs
        record.extents  = extents
        record.blocks   = keep
        record.size     = bytes
        record.modified = now

        // Published, then made durable, and only then given back. A failure at
        // either of the first two steps leaves the record owning every block it
        // owned before, all of them still marked used: the disk is exactly as it
        // was.
        guard store(record, at: index) == .ok else { return .deviceFailed }
        guard barrier() == .ok else { return .deviceFailed }

        for run in 0..<freed {
            releaseRun(start: freeing[run].start, count: freeing[run].count)
        }

        refund(given, to: index)

        return .ok
    }


    /// Zeroes the blocks between where an object had reached and where a write is
    /// about to start.
    ///
    /// A write past the end of a file leaves a gap, and the gap is made of blocks
    /// this object was handed a moment ago with somebody else's bytes still in
    /// them. Nothing in the write loop goes near them, and the moment the size
    /// grows past them a read will. So they are filled in here, once, and only
    /// the ones that need it: the blocks the write itself covers are covered by
    /// the write.
    ///
    /// The alternative was zeroing every block at the moment it is allocated,
    /// which costs a write per block on the commonest path there is - appending
    /// to a file - to fix a leak that only a gap can open. This costs a write per
    /// block of gap, which is a write per block that a sparse write actually
    /// skipped.
    private mutating func zeroUntouched(
        _      record: FSObject,
        beyond held  : UInt64,
        upTo   offset: UInt64
    ) -> FSStatus {

        // The first block wholly past what the object held, and the first the
        // write will touch. A block straddling `held` keeps this object's own
        // bytes and is already zero above them, because the write that made it
        // wrote the whole block.
        var index  = FSLayout.divideUp(held, FSLayout.blockSize)
        let stop   = offset / FSLayout.blockSize

        while index < stop {
            guard let block = record.block(at: index * FSLayout.blockSize) else {
                return .notFound
            }

            guard zeroBlock(block) == .ok else { return .deviceFailed }

            index += 1
        }

        return .ok
    }


    /// Gives `record` enough blocks to hold `bytes`, and writes it back when it
    /// grew.
    ///
    /// The blocks are claimed before any of them is written to, so a growth
    /// that cannot be finished is undone rather than half done. Half a file is
    /// worse than no file: it is a file whose size is a lie.
    private mutating func grow(
        _ record: inout FSObject,
        to bytes: UInt64,
        of index: UInt32
    ) -> FSStatus {

        let needed = FSLayout.divideUp(bytes, FSLayout.blockSize)
        guard needed > UInt64(record.blocks) else { return .ok }

        // Where a sixty-four bit offset a client chose meets thirty-two bit
        // arithmetic about a disk. A file cannot want more blocks than the disk
        // has, so this is a refusal - and it has to be one, because the
        // conversion below traps and the number on the left came out of a
        // message.
        guard needed <= UInt64(plan.totalBlocks) else { return .noSpace }

        let extra = UInt32(needed) - record.blocks

        let booked = charge(extra, to: index)
        guard booked == .ok else { return booked }

        // Re-read for the same reason `link` does: charging rewrites the
        // container's record, and a folder that is itself a container has just
        // had the copy in hand go stale.
        guard let reread = object(index) else {
            refund(extra, to: index)
            return explain(.notFound)
        }
        record = reread

        var missing = extra

        while missing > 0 {

            // Straight after what this object already holds, if those blocks
            // are free. That is what keeps a file that grows in one extent,
            // and it is the difference between a file the disk can read in one
            // request and a file it reads in eight.
            if record.extents > 0 {
                let last = record.runs[Int(record.extents) - 1]

                if allocateAt(last.start + last.count, count: missing) {
                    guard record.append(start: last.start + last.count, count: missing) else {
                        releaseRun(start: last.start + last.count, count: missing)
                        refund(missing, to: index)
                        return .tooFragmented
                    }

                    missing = 0
                    continue
                }
            }

            guard let run = allocateUpTo(missing) else {
                refund(missing, to: index)
                return explain(.noSpace)
            }

            guard record.append(start: run.start, count: run.count) else {
                releaseRun(start: run.start, count: run.count)
                refund(missing, to: index)
                return .tooFragmented
            }

            missing -= run.count
        }

        record.modified = now

        return store(record, at: index)
    }


    /// Rewrites an object's blocks into one run, when the disk has one to
    /// spare.
    ///
    /// This is what stops `tooFragmented` being a dead end. A file that has run
    /// out of extents has not run out of disk: it has run out of *places to
    /// remember where its pieces are*. Moving the pieces together frees seven of
    /// the eight, and the file carries on growing.
    ///
    /// The new run is taken before the old one is released, so a failure
    /// halfway leaves the object exactly as it was. Twice the space is needed
    /// for the moment of the copy, which is the honest cost of not having a
    /// journal to roll back with.
    ///
    /// And the old runs are released only once the record naming the new one is
    /// on the medium. They used to go first, which meant a crash in between left
    /// a file whose extents pointed at blocks the map had already given back.
    public mutating func compact(_ index: UInt32) -> FSStatus {

        guard var record = object(index) else { return .notFound }
        guard record.kind == .file, record.blocks > 0 else { return .ok }
        guard record.extents > 1 else { return .ok }

        guard let fresh = allocateRun(record.blocks) else {
            return explain(.noSpace)
        }

        var written = UInt32(0)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                guard readBlock(block, into: dataBuffer) == .ok,
                      writeBlock(fresh + written, from: dataBuffer) == .ok
                else {
                    releaseRun(start: fresh, count: record.blocks)
                    return .deviceFailed
                }

                written += 1
            }
        }

        // Kept, because publishing the new run is about to overwrite them and
        // they are what has to be given back afterwards.
        let old      = record.runs
        let oldCount = Int(record.extents)

        var runs = InlineArray<8, FSExtent>(repeating: FSExtent())
        runs[0] = FSExtent(start: fresh, count: record.blocks)

        record.runs     = runs
        record.extents  = 1
        record.modified = now

        guard store(record, at: index) == .ok else {
            // The copy is wasted and the old run is still the file's. Giving the
            // new blocks back is safe because nothing on the disk names them.
            releaseRun(start: fresh, count: record.blocks)
            return .deviceFailed
        }

        guard barrier() == .ok else { return .deviceFailed }

        for run in 0..<oldCount {
            releaseRun(start: old[run].start, count: old[run].count)
        }

        return .ok
    }


    /// Cuts a file to `bytes`, or to nothing when no length is given.
    public mutating func truncate(
        _  index: UInt32,
        to bytes: UInt64 = 0
    ) -> FSStatus {

        guard var record = object(index) else { return .notFound }
        guard record.kind == .file else { return .wrongKind }
        guard bytes < record.size else { return .ok }

        return shrink(&record, toBytes: bytes, of: index)
    }

}

@inline(__always)
func min(_ a: UInt64, _ b: UInt64) -> UInt64 { a < b ? a : b }
