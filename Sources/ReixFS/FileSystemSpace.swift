//
//  FileSystemSpace.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Who owns which block, and which object records own them.
///
/// The bitmap is one bit per block and the object table is a flat array, both
/// read a block at a time through the metadata scratch. Every one of those reads
/// goes through `readBlock`, which holds the last few of them: on a disk this
/// size the bitmap is one block and every record here is in one table block, so
/// a whole write path asks the disk for neither of them more than once.
///
/// The loops below still each load a bitmap block exactly once rather than
/// leaning on that. A cache turning a mistake from thirty-two round trips into
/// thirty-two lookups is not the same as not making it.
extension FileSystem {

    // MARK: - The block bitmap

    /// How many blocks one block of bitmap accounts for.
    static var blocksPerBitmapBlock: UInt64 { FSLayout.blockSize * 8 }

    /// Which bitmap block holds the bit for `block`.
    func bitmapBlock(for block: UInt32) -> UInt32 {
        plan.bitmapStart + UInt32(UInt64(block) / Self.blocksPerBitmapBlock)
    }

    /// Where in a loaded bitmap block that bit sits.
    static func bitmapBit(of block: UInt32) -> (byte: Int, bit: UInt8) {
        let inside = UInt64(block) % blocksPerBitmapBlock
        return (Int(inside / 8), UInt8(inside % 8))
    }


    /// Whether `block` is spoken for.
    mutating func isUsed(_ block: UInt32) -> Bool {

        guard block < plan.totalBlocks,
              readBlock(bitmapBlock(for: block), into: metaBuffer) == .ok
        else { return true }

        let place = Self.bitmapBit(of: block)
        let byte  = metaBuffer.loadUnaligned(fromByteOffset: place.byte, as: UInt8.self)

        return byte & (1 << place.bit) != 0
    }


    /// Claims or releases a run of blocks, loading each bitmap block it touches
    /// exactly once.
    ///
    /// One bitmap block covers thirty-two thousand blocks, so almost every run
    /// this is asked about lies inside one of them and costs one read and one
    /// write. Doing it a bit at a time instead cost a round trip per block,
    /// which on a real disk was the difference between a mount taking a moment
    /// and taking forty seconds. Measured, not guessed.
    mutating func setRange(
        start: UInt32,
        count: UInt32,
        used : Bool
    ) -> FSStatus {

        guard count > 0 else { return .ok }
        guard UInt64(start) + UInt64(count) <= UInt64(plan.totalBlocks) else { return .noSpace }

        var done = UInt32(0)

        while done < count {
            let which = bitmapBlock(for: start + done)

            guard readBlock(which, into: metaBuffer) == .ok else { return .deviceFailed }

            while done < count, bitmapBlock(for: start + done) == which {
                let place = Self.bitmapBit(of: start + done)
                var byte  = metaBuffer.loadUnaligned(fromByteOffset: place.byte, as: UInt8.self)

                if used { byte |=  (1 << place.bit) }
                else    { byte &= ~(1 << place.bit) }

                metaBuffer.storeBytes(of: byte, toByteOffset: place.byte, as: UInt8.self)
                done += 1
            }

            guard writeBlock(which, from: metaBuffer) == .ok else { return .deviceFailed }
        }

        return .ok
    }


    /// Claims or releases one block.
    @inline(__always)
    mutating func setUsed(
        _ block: UInt32,
        _ used : Bool
        
    ) -> FSStatus { setRange(start: block, count: 1, used: used) }


    /// Whether every block of `[start, start + count)` is free, loading each
    /// bitmap block it touches exactly once.
    ///
    /// The read-only half of `setRange`, and it exists for the same reason: this
    /// question used to be asked one block at a time through `isUsed`, which
    /// loads a bitmap block per call. Asking about a run of thirty-two cost
    /// thirty-two reads of the same block. Measured at 33 reads and 1 write for
    /// one such run, against the 1 and 1 the caller's comment claimed.
    ///
    /// An unreadable bitmap block answers "not free", the same way `isUsed`
    /// answers "taken": the one direction that cannot hand out a block twice.
    mutating func allFree(
        start: UInt32,
        count: UInt32
    ) -> Bool {

        guard count > 0,
              UInt64(start) + UInt64(count) <= UInt64(plan.totalBlocks)
        else { return false }

        var done   = UInt32(0)
        var loaded : UInt32? = nil

        while done < count {
            let which = bitmapBlock(for: start + done)

            if loaded != which {
                guard readBlock(which, into: metaBuffer) == .ok else { return false }
                loaded = which
            }

            let place = Self.bitmapBit(of: start + done)
            let byte  = metaBuffer.loadUnaligned(fromByteOffset: place.byte, as: UInt8.self)

            guard byte & (1 << place.bit) == 0 else { return false }

            done += 1
        }

        return true
    }


    /// Finds `count` blocks in a row and claims them.
    ///
    /// First fit, scanned from the start of the data region, one bitmap block
    /// held at a time. A better allocator is a real subject; this one's failure
    /// mode is fragmentation, which the extent limit turns into a refusal rather
    /// than into corruption.
    public mutating func allocateRun(_ count: UInt32) -> UInt32? {

        guard count > 0 else { return nil }

        // From where the last one came from, then round to the beginning. A
        // disk that is filling up has its free space at the end, and starting
        // at the front every time meant walking the used part again for every
        // block allocated.
        if blockHint > plan.dataStart, let found = sweep(count, from: blockHint) {
            return found
        }

        return sweep(count, from: plan.dataStart)
    }


    /// Looks for `count` blocks in a row from `first` to the end of the disk.
    private mutating func sweep(
        _    count: UInt32,
        from first: UInt32
    ) -> UInt32? {

        var start   = first
        var running = UInt32(0)
        var loaded : UInt32? = nil

        var block = first

        while block < plan.totalBlocks {
            let which = bitmapBlock(for: block)

            if loaded != which {
                guard readBlock(which, into: metaBuffer) == .ok else { return nil }
                loaded = which
            }

            let place = Self.bitmapBit(of: block)
            let byte  = metaBuffer.loadUnaligned(fromByteOffset: place.byte, as: UInt8.self)

            if byte & (1 << place.bit) != 0 {
                running = 0
                start   = block + 1

            } else {
                running += 1

                if running == count {
                    guard setRange(start: start, count: count, used: true) == .ok else {
                        return nil
                    }

                    blockHint = start + count
                    return start
                }
            }

            block += 1
        }

        return nil
    }


    /// Claims exactly the blocks `[start, start + count)`, and only if every
    /// one of them is free.
    ///
    /// What a growing file asks for first: the blocks immediately after the ones
    /// it already has. Getting them is what keeps the file in one extent, and
    /// almost always it costs one read of the bitmap to find out, because one
    /// bitmap block covers thirty-two thousand blocks.
    ///
    /// "Almost always" and not "always": a run that straddles the boundary
    /// between two bitmap blocks reads both. What it no longer does is read one
    /// of them once per block in the run.
    mutating func allocateAt(
        _ start: UInt32,
          count: UInt32
    ) -> Bool {

        guard count > 0,
              start >= plan.dataStart,
              allFree(start: start, count: count)
        else { return false }

        guard setRange(start: start, count: count, used: true) == .ok else { return false }

        blockHint = start + count
        return true
    }


    /// Claims as many of `wanted` blocks as one run can give: all of them, or
    /// one when the disk is too broken up for that.
    ///
    /// The two-step is what keeps a growing file in as few extents as the disk
    /// allows without a search for the best hole. Falling back to one block at a
    /// time is slow and always works while there is any space at all, which is
    /// the right shape for a fallback.
    mutating func allocateUpTo(_ wanted: UInt32) -> (start: UInt32, count: UInt32)? {

        if let run = allocateRun(wanted) { return (run, wanted) }
        if wanted > 1, let one = allocateRun(1) { return (one, 1) }

        return nil
    }


    /// Gives `count` blocks back, starting at `start`.
    public mutating func releaseRun(
        start: UInt32,
        count: UInt32
    ) {
        guard count > 0, start >= plan.dataStart else { return }

        _ = setRange(start: start, count: count, used: false)
    }


    /// How many blocks are free. One read per bitmap block, so on this disk one
    /// read: still a question to ask when somebody asks, not in a loop.
    public mutating func freeBlocks() -> UInt32 {

        var free   = UInt32(0)
        var loaded : UInt32? = nil

        for block in plan.dataStart..<plan.totalBlocks {
            let which = bitmapBlock(for: block)

            if loaded != which {
                guard readBlock(which, into: metaBuffer) == .ok else { return free }
                loaded = which
            }

            let place = Self.bitmapBit(of: block)
            let byte  = metaBuffer.loadUnaligned(fromByteOffset: place.byte, as: UInt8.self)

            if byte & (1 << place.bit) == 0 { free += 1 }
        }

        return free
    }


    // MARK: - The object table

    /// Reads one object record, if what is there is a record.
    ///
    /// The one door every record comes through, which is why the asking happens
    /// here: a record that could not describe anything on this disk is not
    /// returned at all, so nothing downstream has to wonder. `nil` reads the
    /// same as "there is nothing at that number", which every caller already
    /// handles, and the volume is held still on the way out.
    public mutating func object(_ index: UInt32) -> FSObject? {

        guard let place = tablePlace(of: index),
              readBlock(place.block, into: metaBuffer) == .ok
        else { return nil }

        let record = FSObject(reading: metaBuffer.advanced(by: place.offset))

        guard record.fits(plan) else {
            quarantine()
            return nil
        }

        return record
    }


    /// Writes one object record back.
    mutating func store(
        _  object: FSObject,
        at index: UInt32
    ) -> FSStatus {

        guard let place = tablePlace(of: index) else { return .notFound }
        guard readBlock(place.block, into: metaBuffer) == .ok else { return .deviceFailed }

        object.write(to: metaBuffer.advanced(by: place.offset))

        return writeBlock(place.block, from: metaBuffer)
    }


    private func tablePlace(of index: UInt32) -> (block: UInt32, offset: Int)? {

        guard index < plan.objectCount else { return nil }

        let byte = UInt64(index) * FSLayout.objectSize

        return (
            plan.tableStart + UInt32(byte / FSLayout.blockSize),
            Int(byte % FSLayout.blockSize)
        )
    }


    /// Takes a free slot in the table and writes an empty object of `kind` into
    /// it. `nil` when the table is full, which is its own kind of disk-full.
    mutating func allocateObject(kind: FSKind) -> UInt32? {

        let perBlock = UInt32(FSLayout.blockSize / FSLayout.objectSize)

        // A table block at a time, not an object at a time, and starting where
        // the last free slot was found. The first costs one read per sixty-four
        // records instead of one per record; the second stops the search
        // getting longer as the disk fills.
        let first = objectHint / perBlock

        for step in 0..<plan.tableBlocks {
            let table = (first + step) % plan.tableBlocks
            let which = plan.tableStart + table

            guard readBlock(which, into: metaBuffer) == .ok else { return nil }

            for slot in 0..<Int(perBlock) {
                let at = slot * Int(FSLayout.objectSize)
                let free = FSObject(reading: metaBuffer.advanced(by: at))
                guard free.kind == .free else { continue }

                // The generation is the slot's and not the object's, so it
                // carries across whoever is holding it: a fresh record here
                // would reset the count and let a capability from two objects
                // ago name this one.
                var fresh = FSObject(kind: kind, created: now)
                fresh.generation = free.generation

                fresh.write(to: metaBuffer.advanced(by: at))

                guard writeBlock(which, from: metaBuffer) == .ok else { return nil }

                let index = table * perBlock + UInt32(slot)
                objectHint = index + 1

                return index
            }
        }

        return nil
    }


    /// Releases an object and every block it held.
    ///
    /// The record goes first and the blocks after it, which is the ordering rule
    /// on `barrier`: from the moment the slot reads free, nothing on the disk
    /// points at those blocks, so handing them out cannot hand out a block
    /// something still claims. The other way round - blocks first - left a
    /// window in which a live record named blocks the map had already given
    /// away, and no later check can undo that.
    mutating func releaseObject(_ index: UInt32) -> FSStatus {

        guard let held = object(index) else { return .notFound }

        // Worked out before the record goes, because it is the record that says
        // which container the blocks belong to, and a freed record says nothing.
        let owner = held.blocks > 0 ? charged(index) : nil

        // Bumped here rather than when the slot is next taken, so that every
        // capability naming this object stops working the moment the object is
        // removed - not the moment somebody else is given its slot. The free
        // record keeps the count, which is the only reason it can be believed.
        var empty = FSObject()
        empty.generation = held.generation &+ 1

        guard store(empty, at: index) == .ok else { return .deviceFailed }
        guard barrier() == .ok else { return .deviceFailed }

        for run in 0..<Int(held.extents) {
            releaseRun(start: held.runs[run].start, count: held.runs[run].count)
        }

        if let owner { refund(held.blocks, toContainer: owner) }

        // The slot just freed is the best guess for where the next one is.
        objectHint = index

        return .ok
    }
}
