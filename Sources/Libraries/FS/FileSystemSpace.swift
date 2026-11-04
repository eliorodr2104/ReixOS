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

    public struct FreeBlocksResult {
        public let status: FSStatus
        public let value : UInt32

        init(_ status: FSStatus, _ value: UInt32 = 0) {
            self.status = status
            self.value  = value
        }
    }

    enum ObjectRead {
        case live(FSObject)
        case free(FSObject)
        case outside
        case failed(FSStatus)
        case corrupt

        var refusal: FSStatus {
            switch self {
                case .live:            return .ok
                case .free, .outside:  return .notFound
                case .failed(let why): return why
                case .corrupt:         return .quarantined
            }
        }
    }

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

    /// How many blocks one word of the map accounts for.
    ///
    /// The scans below take the map a word at a time where they can, because a
    /// bit at a time is a division, a shift and a load for every block on the
    /// disk. Measured on a disk with every other block used: the worst scan
    /// there is - looking for two blocks in a row and finding none - cost more
    /// than a whole journalled write at four thousand blocks, and fifty times one
    /// at sixty-five thousand. The word is loaded in the machine's own byte
    /// order, which is the order everything else in this format is written in.
    static var blocksPerWord: UInt32 { 64 }


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
    ///
    /// Every bitmap block the run touches is counted before the first of them is
    /// staged, so a run that would want a seventeenth after-image is refused
    /// whole rather than half written and then abandoned. The staging door sees
    /// one block at a time and cannot do that: by the moment it says no, the
    /// earlier images are already in the journal.
    mutating func setRange(
        start: UInt32,
        count: UInt32,
        used : Bool
    ) -> FSStatus {

        guard count > 0 else { return .ok }
        guard UInt64(start) + UInt64(count) <= UInt64(plan.totalBlocks) else { return .noSpace }

        // Before the first image, not after the sixteenth. See
        // `FSTransaction.room(from:through:)`.
        let room = roomToStage(
            from   : bitmapBlock(for: start),
            through: bitmapBlock(for: start + count - 1)
        )
        guard room == .ok else { return room }

        var done = UInt32(0)

        while done < count {
            let which = bitmapBlock(for: start + done)

            let loaded = readBlock(which, into: metaBuffer)
            guard loaded == .ok else { return loaded }

            // As much of the run as lies inside this bitmap block, in one pass
            // over its words rather than one per block.
            let inside = Int(UInt64(start + done) % Self.blocksPerBitmapBlock)
            let width  = min(Int(count - done), Int(Self.blocksPerBitmapBlock) - inside)

            FSBitmap.set(metaBuffer, from: inside, count: width, used: used)

            let staged = stageStructuralBlock(which, from: metaBuffer)
            guard staged == .ok else { return staged }

            done += UInt32(width)
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

            let inside = Int(UInt64(start + done) % Self.blocksPerBitmapBlock)
            let width  = min(Int(count - done), Int(Self.blocksPerBitmapBlock) - inside)

            guard FSBitmap.allClear(metaBuffer, from: inside, count: width) else {
                return false
            }

            done += UInt32(width)
        }

        return true
    }


    /// Finds `count` blocks in a row and claims them.
    ///
    /// First fit, scanned from the start of the data region, one bitmap block
    /// held at a time. A better allocator is a real subject; this one's failure
    /// mode is fragmentation, which the extent limit turns into a refusal rather
    /// than into corruption.
    ///
    /// Only `noSpace` falls through from the hinted sweep to the one that starts
    /// at the beginning. A disk that has stopped answering, or a transaction with
    /// no room left for another image, would answer the same way twice, and the
    /// second walk is a walk of the whole disk for nothing.
    mutating func allocateRun(_ count: UInt32) -> FSRun {

        guard count > 0 else { return .refused(.noSpace) }

        // From where the last one came from, then round to the beginning. A
        // disk that is filling up has its free space at the end, and starting
        // at the front every time meant walking the used part again for every
        // block allocated.
        //
        if blockHint > plan.dataStart {
            let hinted = sweep(count, from: blockHint)
            guard hinted.refusal == .noSpace else { return hinted }
        }

        return sweep(count, from: plan.dataStart)
    }


    /// Looks for `count` blocks in a row from `first` to the end of the disk.
    private mutating func sweep(
        _    count: UInt32,
        from first: UInt32
    ) -> FSRun {

        var block = first

        // Free blocks at the end of the previous bitmap block, and where they
        // began. The only stitching left: `FSBitmap.firstRun` joins words itself.
        var carry      = UInt32(0)
        var carryStart = UInt32(0)

        while block < plan.totalBlocks {
            let which = bitmapBlock(for: block)

            let fetched = readBlock(which, into: metaBuffer)
            guard fetched == .ok else { return .refused(fetched) }

            // How many of this block's bits are blocks of this disk. The ones
            // after the last are zero and are not free space.
            let base = UInt64(which - plan.bitmapStart) * Self.blocksPerBitmapBlock
            let bits = Int(min(
                Self.blocksPerBitmapBlock, UInt64(plan.totalBlocks) - base
            ))

            let inside = Int(UInt64(block) - base)

            // A run carried over the boundary, finished by what this block begins
            // with.
            if carry > 0, inside == 0 {
                let lead = UInt32(FSBitmap.leadingClear(metaBuffer, bits: bits))

                if carry + lead >= count {
                    let claimed = setRange(start: carryStart, count: count, used: true)
                    guard claimed == .ok else { return .refused(claimed) }

                    blockHint = carryStart + count
                    return .taken(start: carryStart, count: count)
                }
            }

            if let found = FSBitmap.firstRun(
                metaBuffer, ofAtLeast: Int(count), from: inside, bits: bits
            ) {
                let start = UInt32(base) + UInt32(found)

                let claimed = setRange(start: start, count: count, used: true)
                guard claimed == .ok else { return .refused(claimed) }

                blockHint = start + count
                return .taken(start: start, count: count)
            }

            // Nothing wide enough here. What can still help is the run at the end
            // of this block, joined to whatever the next one begins with.
            let trail = UInt32(FSBitmap.trailingClear(metaBuffer, bits: bits))

            carry      = trail
            carryStart = UInt32(base) + UInt32(bits) - trail

            block = UInt32(base) + UInt32(bits)
        }

        return .refused(explain(.noSpace))
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
    ///
    /// `noSpace` is the only refusal a caller may read as a hint to look
    /// elsewhere. Everything else is a refusal about the volume, and a growth
    /// that treated one of those as "those blocks are taken" would go on
    /// searching a disk that has stopped answering.
    mutating func allocateAt(
        _ start: UInt32,
          count: UInt32
    ) -> FSStatus {

        guard count > 0, start >= plan.dataStart else { return .noSpace }

        // `explain` because an unreadable bitmap block also reads as "taken", and
        // a growth must not go on searching a disk that has gone away.
        guard allFree(start: start, count: count) else { return explain(.noSpace) }

        let claimed = setRange(start: start, count: count, used: true)
        guard claimed == .ok else { return claimed }

        blockHint = start + count
        return .ok
    }


    /// Claims as many of `wanted` blocks as one run can give: all of them, or
    /// one when the disk is too broken up for that.
    ///
    /// The two-step is what keeps a growing file in as few extents as the disk
    /// allows without a search for the best hole. Falling back to one block at a
    /// time is slow and always works while there is any space at all, which is
    /// the right shape for a fallback.
    ///
    /// Only `noSpace` falls back. A disk that stopped answering would answer the
    /// same way to a run of one, and asking it again is a walk for nothing.
    mutating func allocateUpTo(_ wanted: UInt32) -> FSRun {

        let whole = allocateRun(wanted)
        guard whole.refusal == .noSpace, wanted > 1 else { return whole }

        return allocateRun(1)
    }


    /// Gives `count` blocks back, starting at `start`.
    ///
    /// A status and not a `Bool`, and that change closed the worst hole this
    /// format had: a release that did not happen is a block marked used that
    /// nobody owns, every caller turned the old `false` into `ok`, and a truncate
    /// could therefore report success with its blocks never given back.
    ///
    /// Nothing to release is success; a run below the data region is a caller
    /// asking for something this cannot do, and it poisons the transaction rather
    /// than being answered quietly.
    mutating func releaseRun(
        start: UInt32,
        count: UInt32
    ) -> FSStatus {
        guard count > 0 else { return .ok }

        // Below the data region is not a run this can give back, and a record
        // that named one is a record `fits` would have refused.
        guard start >= plan.dataStart else { return staging(refused: .deviceFailed) }

        return setRange(start: start, count: count, used: false)
    }


    /// How many blocks are free. One read per bitmap block, so on this disk one
    /// read: still a question to ask when somebody asks, not in a loop.
    ///
    /// A word at a time where the word is wholly inside the disk, for the reason
    /// `blocksPerWord` gives: this walks every block on the disk and it is on the
    /// path of `fs.free` and of every space check a client makes.
    public mutating func freeBlocksResult() -> FreeBlocksResult {

        var free = UInt32(0)

        for map in 0..<plan.bitmapBlocks {
            let base = UInt64(map) * Self.blocksPerBitmapBlock
            guard base < UInt64(plan.totalBlocks) else { break }

            let loaded = readBlock(plan.bitmapStart + map, into: metaBuffer)
            guard loaded == .ok else {
                return FreeBlocksResult(loaded)
            }

            // The data region only, and only as far as the disk goes. The front
            // of the disk is the file system's own and is used by definition.
            let bits  = Int(min(
                Self.blocksPerBitmapBlock, UInt64(plan.totalBlocks) - base
            ))
            let first = base < UInt64(plan.dataStart)
                ? Int(UInt64(plan.dataStart) - base)
                : 0

            guard first < bits else { continue }

            free += UInt32(FSBitmap.clearCount(
                metaBuffer, from: first, count: bits - first
            ))
        }

        return FreeBlocksResult(.ok, free)
    }


    public mutating func freeBlocks() -> UInt32 {
        freeBlocksResult().value
    }


    // MARK: - The object table

    /// Reads one object record, if what is there is a record.
    ///
    /// The one door every record comes through, which is why the asking happens
    /// here: a record that could not describe anything on this disk is not
    /// returned at all, so nothing downstream has to wonder. `nil` reads the
    /// same as "there is nothing at that number", which every caller already
    /// handles, and the volume is held still on the way out.
    mutating func readObject(_ index: UInt32) -> ObjectRead {

        guard let place = tablePlace(of: index) else { return .outside }

        let loaded = readBlock(place.block, into: metaBuffer)
        guard loaded == .ok else { return .failed(loaded) }

        let record = FSObject(reading: metaBuffer.advanced(by: place.offset))

        guard record.standing != .impossible else {
            quarantine()
            return .corrupt
        }

        guard record.fits(plan) else {
            quarantine()
            return .corrupt
        }

        // Its own parent, and not the root: the one shape of loop a single
        // record shows, seen at the door every record comes through.
        guard index == FSLayout.rootObject
                || record.standing != .live
                || record.parent != index
        else {
            quarantine()
            return .corrupt
        }

        return record.standing == .live ? .live(record) : .free(record)
    }


    public mutating func object(_ index: UInt32) -> FSObject? {
        switch readObject(index) {
            case .live(let record), .free(let record): return record
            case .outside, .failed, .corrupt:           return nil
        }
    }


    /// Writes one object record back.
    mutating func store(
        _  object: FSObject,
        at index: UInt32
    ) -> FSStatus {

        guard let place = tablePlace(of: index) else { return .notFound }
        guard readBlock(place.block, into: metaBuffer) == .ok else { return .deviceFailed }

        object.write(to: metaBuffer.advanced(by: place.offset))

        return stageStructuralBlock(place.block, from: metaBuffer)
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
    /// it. Refused when the table is full, which is its own kind of disk-full.
    ///
    /// Free means `standing == .free` and never `kind == .free`. The two parted
    /// company when the kind stopped being clamped in silence: a record whose
    /// kind byte is not a kind reads as free, and handing that slot out would
    /// hand out blocks the map still calls used.
    mutating func allocateObject(kind: FSKind) -> FSFound {

        let perBlock = UInt32(FSLayout.blockSize / FSLayout.objectSize)

        // A table block at a time, not an object at a time, and starting where
        // the last free slot was found. The first costs one read per sixty-four
        // records instead of one per record; the second stops the search
        // getting longer as the disk fills.
        let first = objectHint / perBlock

        for step in 0..<plan.tableBlocks {
            let table = (first + step) % plan.tableBlocks
            let which = plan.tableStart + table

            let loaded = readBlock(which, into: metaBuffer)
            guard loaded == .ok else { return .refused(loaded) }

            for slot in 0..<Int(perBlock) {
                let at = slot * Int(FSLayout.objectSize)
                let free = FSObject(reading: metaBuffer.advanced(by: at))

                switch free.standing {
                    case .live: continue

                    // A kind byte this format never writes was clamped to
                    // `.free`, so this loop used to hand the slot out.
                    case .impossible:
                        quarantine()
                        return .refused(.quarantined)

                    case .free: break
                }

                // A slot that has been reused as many times as a capability can
                // tell apart is never handed out again. Skipped rather than
                // counted round, because counting round is the whole hazard: an
                // old capability naming generation zero of this slot would come
                // to name a live file again.
                guard !free.retired else { continue }

                // The generation is the slot's and not the object's, so it
                // carries across whoever is holding it: a fresh record here
                // would reset the count and let a capability from two objects
                // ago name this one.
                var fresh = FSObject(kind: kind, created: now)
                fresh.generation = free.generation
                fresh.flags      = free.flags

                fresh.write(to: metaBuffer.advanced(by: at))

                let staged = stageStructuralBlock(which, from: metaBuffer)
                guard staged == .ok else { return .refused(staged) }

                let index = table * perBlock + UInt32(slot)
                objectHint = index + 1

                return .at(index)
            }
        }

        return .refused(explain(.noSpace))
    }


    /// Releases an object and every block it held.
    ///
    /// The record goes first and the blocks after it, which is the ordering rule
    /// on `barrier`: from the moment the slot reads free, nothing on the disk
    /// points at those blocks, so handing them out cannot hand out a block
    /// something still claims. The other way round - blocks first - left a
    /// window in which a live record named blocks the map had already given
    /// away, and no later check can undo that.
    ///
    /// A record with blocks whose container cannot be worked out is refused
    /// rather than released, because the refund would otherwise be skipped in
    /// silence and the container would never recover its room.
    mutating func releaseObject(_ index: UInt32) -> FSStatus {

        guard let held = object(index) else { return explain(.notFound) }

        // Worked out before the record goes, because it is the record that says
        // which container the blocks belong to, and a freed record says nothing.
        var owner: UInt32? = nil

        if held.blocks > 0 {
            guard let place = charged(index) else { return explain(.notFound) }
            owner = place
        }

        // Bumped here rather than when the slot is next taken, so that every
        // capability naming this object stops working the moment the object is
        // removed - not the moment somebody else is given its slot. The free
        // record keeps the count, which is the only reason it can be believed.
        // The last generation a badge *and* a handle can both tell apart. A slot
        // that reaches it is marked out of use rather than counted round, so the
        // next `create` walks past it and the one after that too - for the rest
        // of the disk's life.
        let limit = FSBadge(objectCount: plan.objectCount)
        let last  = min(limit.lastGeneration, limit.handles.lastGeneration)

        var empty = FSObject()

        if held.generation >= last {
            empty.generation = last
            empty.retired    = true

        } else {
            empty.generation = held.generation &+ 1
            empty.retired    = held.retired
        }

        let freed = store(empty, at: index)
        guard freed == .ok else { return freed }

        // No barrier between the record and the blocks any more. It was there to
        // make one ordering true - free the record first, so a crash leaves a
        // leak rather than a block two objects own - and the transaction around
        // this makes the two one act instead: they land together or not at all.
        for run in 0..<Int(held.extents) {
            let given = releaseRun(
                start: held.runs[run].start, count: held.runs[run].count
            )
            guard given == .ok else { return given }
        }

        if let owner {
            let back = refund(held.blocks, toContainer: owner)
            guard back == .ok else { return back }
        }

        // The slot just freed is the best guess for where the next one is.
        objectHint = index

        return .ok
    }
}
