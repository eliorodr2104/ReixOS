//
//  FileSystemRepair.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Finding out whether the disk still adds up, and only then making it.
///
/// **Three acts, and keeping them apart is the whole of this file.**
///
/// A `scan` reads. It writes nothing, whatever it finds, and it holds the volume
/// still when what it finds is two things on the disk contradicting each other.
///
/// `putRight` is what a dirty mount runs. It corrects exactly the two things that
/// are *functions of the object table* - the block map, and every container's
/// room - because a function can be recomputed. Nothing else is touched, and the
/// reason is one sentence: everything else a scan can find is a disagreement
/// between two accounts, and there is no third account to derive the answer from.
///
/// `repair` is the writing half of the first of those, and it is not public. The
/// only ways to it are from inside this module, with findings just taken. It
/// checks their ticket anyway: "nothing owns these blocks" is a claim about every
/// record there was at one moment, and a mutation since then may have written one
/// of those owners.
///
/// The coupling to `complete` is not tidiness. "No record owns them" is a claim
/// about *every* record: a scan that stopped half way through the object table
/// has not looked at the owner, and freeing on the strength of it would hand a
/// live file's blocks to the next thing that asks. So an unfinished scan repairs
/// nothing, and says so rather than reporting a number that means less than it
/// looks like.
///
/// Depth is a choice because cost is. `blocks` is what a crash can disturb and
/// what a dirty mount pays for; `everything` walks every directory besides, which
/// is a great many more reads and belongs to somebody asking rather than to every
/// boot. The container arithmetic is in neither category and in both: a dirty
/// mount recomputes it because it is cheap next to what it protects, and a deep
/// scan reports it.
/// One more of something, and never one fewer.
///
/// A count of findings is a report, and a report is only useful while it is
/// true. `+= 1` traps at the top of the range and `&+= 1` says there were none,
/// so neither is an answer: saturating is the one that stays true, because "at
/// least this many" is what a caller does anything with.
@inline(__always)
private func found(_ value: inout UInt32, by many: UInt32 = 1) {
    let (sum, over) = value.addingReportingOverflow(many)
    value = over ? UInt32.max : sum
}


extension FileSystem {

    /// How much of the disk a scan looks at.
    public enum Scrub {

        /// The block map against the object table. Bounded, and the only part a
        /// power cut can disturb, so it is what a dirty mount runs.
        case blocks

        /// That, and a walk of every name in every folder, and every container's
        /// room against what is actually charged to it. Reads far more, finds
        /// far more, and is for a person who has reason to ask.
        case everything

        /// That, and every block of every file against its checksum: a read of
        /// all the data on the disk. What `fs.scrub` runs, and nothing else,
        /// because its cost is the size of what is stored.
        case data
    }


    /// What a scan found. Nothing here changed the disk.
    public struct Findings {

        public enum NameScrubState: Equatable {
            case complete
            case budgetExhausted
        }

        /// Whether the scan saw everything it set out to.
        ///
        /// The most important field, because every other number means nothing
        /// without it: a count of blocks nobody owns, taken from a table that
        /// was only half read, is a count of blocks whose owner was not reached.
        /// Repair refuses without this.
        public var complete = false

        /// How deep the scan went, so that a report says what it did not look at
        /// as plainly as what it did.
        public var depth: Scrub = .blocks

        /// Whether the container arithmetic was checked.
        ///
        /// Separate from `complete`, and it used to mean "there were more
        /// containers than the accumulator holds". It cannot mean that any more:
        /// the walk windows over the table, so every container is reached
        /// whatever the disk holds. What is left is the honest reason - a device
        /// that stopped answering part way through the walk.
        public var quotasChecked = false

        public var safeToServe = false

        // MARK: - Which moment this is a report about

        /// The superblock generation when the scan ran.
        ///
        /// Bumped by every mount, so it separates two mounts of one disk: a set
        /// of findings taken before a reboot cannot be applied after it.
        public var generation: UInt64 = 0

        /// How many transactions the volume had committed when the scan ran.
        ///
        /// A scan is a statement about one moment. "Nothing owns these blocks" is
        /// a claim about every record there was *then*, and applying it after a
        /// mutation would free blocks whose owner was written in between. So a
        /// repair takes the ticket and refuses one that does not match exactly.
        ///
        /// There is no third field naming the instance, and it would be a
        /// pretence: a `FileSystem` is a value, so two copies of one mount share
        /// everything a nonce could be made of. What separates two *mounts* is
        /// the generation above, and that is the boundary that matters.
        public var mutations: UInt64 = 0

        // MARK: - Blocks

        /// Blocks the map calls used that no record owns.
        ///
        /// The ordinary residue of a crash, and the only thing here a repair
        /// will touch. Nothing points at them, so giving them back cannot cost
        /// anybody anything - provided the scan that said nothing points at them
        /// actually finished.
        public var reclaimable: UInt32 = 0

        /// Blocks a record owns that the map calls free.
        ///
        /// Under the write order this format keeps, unreachable: blocks are
        /// released only after the record that stopped naming them is on the
        /// medium. So this is not a repair waiting to happen, it is a report
        /// that a write landed out of order or a disk lost one it had
        /// acknowledged.
        public var ownedButFree: UInt32 = 0

        /// Blocks two different records both claim.
        ///
        /// Nothing can be done and nothing is attempted: the two owners are
        /// equally plausible from here, and picking one would be guessing with
        /// somebody's file.
        public var claimedTwice: UInt32 = 0

        /// Records that could not describe anything on this disk.
        public var impossible: UInt32 = 0

        // MARK: - Names

        /// Entries whose target does not agree it is there.
        ///
        /// A name is one folder's way of reaching something and `parent` is the
        /// thing's own account of which folder that is. A name whose target says
        /// otherwise reaches nothing, which is how it is refused at runtime, and
        /// it is worth counting because somebody put it there or something
        /// damaged it.
        public var strayNames: UInt32 = 0

        /// Entries shadowed by an earlier one of the same name in the same
        /// folder. Unreachable, and a name nobody can use is a thing nobody can
        /// delete.
        public var duplicateNames: UInt32 = 0

        public var duplicateTargets: UInt32 = 0

        public var nameScrubState: NameScrubState = .complete

        public var nameScrubBudgetExhausted: Bool {
            nameScrubState == .budgetExhausted
        }

        /// Slots in a folder whose bytes are not an entry at all.
        ///
        /// A length past the field, or a name holding a character no name may
        /// hold. Both are clamped when they are read so that nothing walks off
        /// the end of the field, and the clamp made them look like unused slots:
        /// `link` would lay a name over one and this walk would not see it.
        public var brokenEntries: UInt32 = 0

        /// Objects that are their own parent and are not the machine's root.
        ///
        /// The one shape of loop this can see without a table's worth of memory.
        /// Longer ones are not looked for and are not dangerous either: every
        /// walk up a parent chain is bounded, so a loop costs reachability
        /// rather than safety.
        public var selfParented: UInt32 = 0

        // MARK: - Data

        /// Blocks of file data that do not checksum to what was last written
        /// there. Counted by a `data` scan only.
        ///
        /// Reported and not held: nothing else on the disk is built on a file's
        /// bytes, and a read of one of these is already refused as `damaged`.
        public var damagedData: UInt32 = 0

        // MARK: - Room

        /// Containers whose `used` disagrees with the blocks actually charged
        /// to them.
        public var wrongQuota: UInt32 = 0

        /// Live records charged to something that is not a live container.
        ///
        /// A quota that adds up to no container. Nothing writing this disk can
        /// make one - `charged` refuses it at runtime - and there is no third
        /// account to derive the right answer from, so it is said and held.
        public var strayCharges: UInt32 = 0

        /// Whether the disk holds more containers than this format keeps an index
        /// of, in which case the room was not checked at all.
        ///
        /// Separate from `quotasChecked`, which is a device that stopped
        /// answering: this one is a disk this build is not sized for. See
        /// `FSLayout.maxContainers`.
        public var tooManyContainers = false

        /// How many of those were recomputed rather than reported.
        ///
        /// Only a dirty mount does it, and the difference is the whole rule: a
        /// volume that was interrupted has arithmetic that is behind, and a volume
        /// that was not has arithmetic that is wrong. One is finished, the other
        /// is held.
        public var roomsMended: UInt32 = 0

        /// Whether the block map was actually rewritten.
        ///
        /// The other half of `repairable`, and it was missing: the repair's own
        /// status was discarded, so a caller could be handed findings saying the
        /// map *could* be put right by a call that had already tried and been
        /// refused. A disk served on the strength of that is a disk whose map is
        /// still the one the crash left.
        public var mapMended = false


        /// Whether the map on the disk disagreed with the object table.
        public var changed: Bool { reclaimable > 0 || ownedButFree > 0 }

        /// Whether anything was found that no repair here can put right.
        ///
        /// Reporting, not gating. Every one of these is a disagreement between
        /// two things on the disk, and choosing a winner would be guessing with
        /// somebody's file - so they are said and left, and they also hold the
        /// volume still, which stops the repair below on their own.
        public var damaged: Bool {
            claimedTwice > 0 || impossible > 0
                || strayNames > 0 || duplicateNames > 0 || duplicateTargets > 0
                || brokenEntries > 0 || nameScrubBudgetExhausted
                || selfParented > 0 || wrongQuota > 0 || strayCharges > 0
        }

        /// What no derivation can put right.
        ///
        /// The map and every container's room are functions of the object table,
        /// so both can be recomputed. Everything here is two things on the disk
        /// contradicting each other - two records claiming one block, a record
        /// that cannot be true, a name whose target disagrees - and there is no
        /// third thing to derive the answer from. Choosing between them would be
        /// guessing with somebody's file, so the volume is held instead.
        ///
        /// A room that was *recomputed* is not here, which is the difference
        /// between putting something right and finding it wrong.
        public var unfixable: Bool {
            claimedTwice > 0 || impossible > 0
                || strayNames > 0 || duplicateNames > 0 || duplicateTargets > 0
                || brokenEntries > 0 || nameScrubBudgetExhausted
                || selfParented > 0 || strayCharges > 0
                || wrongQuota > roomsMended
        }

        /// Whether the map may be rebuilt from the table.
        ///
        /// The repair is one act - the map written out from what the records
        /// say - and it does two things in the same stroke: frees what nobody
        /// owns, and marks used what somebody does. Both are the conservative
        /// direction. Neither can hand a block to a second owner, so the
        /// question is never whether either half is safe on its own; it is
        /// whether the table they were both read from was read *whole*.
        ///
        /// Two ways it was not. A scan that stopped has not reached every owner.
        /// And a record it could not parse is precisely an owner it did not
        /// understand - rebuilding without it would free that record's blocks
        /// for having been unreadable, which is the one outcome worth refusing
        /// over. Note that such a record also quarantines the volume, so this
        /// says out loud what `writeBlock` would enforce anyway.
        public var repairable: Bool { changed && complete && impossible == 0 }
    }


    // MARK: - Scanning

    /// Holds the volume still over a scan's finding, unless the scan is the one
    /// a shutdown runs to decide on a seal. See `scanHolds`.
    private mutating func hold() {
        if scanHolds { quarantine() }
    }

    /// Reads the disk and says what it found. Writes nothing, ever.
    public mutating func scan(_ depth: Scrub = .blocks) -> Findings {
        look(depth).findings
    }


    /// A scan, and the census its pass over the table took, which the room
    /// walk after it uses instead of a pass of its own.
    ///
    /// The room before the names: the names walk borrows the accumulator page
    /// the census left the quota index in.
    private mutating func look(_ depth: Scrub) -> (findings: Findings, census: Census?) {

        var findings = Findings()
        findings.depth      = depth
        findings.generation = superblockGeneration
        findings.mutations  = mutations

        guard let census = scanBlocks(&findings) else { return (findings, nil) }

        if depth != .blocks {
            guard roomWalk(&findings, census: census, mending: false),
                  scanNames(&findings)
            else { return (findings, census) }
        }

        if depth == .data {
            guard scanData(&findings) else { return (findings, census) }
        }

        settle(&findings)
        return (findings, census)
    }


    /// Marks findings that saw everything they set out to, and says whether
    /// they are enough to serve on.
    private func settle(_ findings: inout Findings) {
        findings.complete = true
        findings.safeToServe = findings.quotasChecked && !findings.tooManyContainers
            && !findings.unfixable && !findings.changed
    }


    /// What one pass over the object table counted besides the block map.
    ///
    /// The containers are left in the accumulator page, ascending, with each
    /// one's `used` at the same position in the data page: that is the quota
    /// index a seal is written from. `owned` and `charged` are the same fact
    /// told twice - what every record holds, and what every container says is
    /// charged to it - and a volume whose two totals disagree is not sealed.
    struct Census {
        var containers        = 0
        var tooManyContainers = false
        var owned  : UInt64   = 0
        var charged: UInt64   = 0
    }


    /// The block map against the object table, in one pass over the table.
    ///
    /// The whole map is built in the journal's arena first, every bitmap block
    /// at once, and only then compared with the map on the disk. It used to be
    /// built a bitmap block at a time, which cost a pass over the whole table per
    /// bitmap block, and both of those grow with the disk. Now it is one pass and
    /// one read per bitmap block, for the price of memory the arena already is.
    ///
    /// A scan reads every table and bitmap block, so a whole one is also what
    /// tells `sums` what the disk holds.
    ///
    /// Nil when the device stopped answering part way.
    @discardableResult
    mutating func scanBlocks(_ findings: inout Findings) -> Census? {

        var census = Census()
        guard buildTruth(&findings, &census) else { return nil }

        let words = Int(FSLayout.blockSize) / FSBitmap.bytesPerWord

        for map in 0..<plan.bitmapBlocks {
            guard readBlock(plan.bitmapStart + map, into: metaBuffer) == .ok else {
                return nil
            }

            let truth = truthPage(map)

            for word in 0..<words {
                let built  = FSBitmap.word(truth, word)
                let stored = FSBitmap.word(metaBuffer, word)

                guard built != stored else { continue }

                found(&findings.reclaimable,  by: UInt32((stored & ~built).nonzeroBitCount))
                found(&findings.ownedButFree, by: UInt32((built & ~stored).nonzeroBitCount))
            }
        }

        // And every sum block, which nothing above reads, when what they hold is
        // still to be learned. Once known, every read of one is checked anyway.
        if !sumsKnown {
            for block in plan.sumStart..<plan.dataStart {
                guard readBlock(block, into: metaBuffer) == .ok else { return nil }
            }
        }

        // Every bitmap, table and sum block has now been read off the medium.
        sumsKnown = true

        containerCount = census.tooManyContainers ? FSLayout.maxContainers : census.containers

        return census
    }


    /// Every block of every file, read and checked against its checksum.
    ///
    /// One pass over the table, and one read per block of data: the whole of
    /// what is stored. False when the device stopped answering, or the table or
    /// a sum block did not check out, which holds the volume.
    private mutating func scanData(_ findings: inout Findings) -> Bool {

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        for table in 0..<plan.tableBlocks {
            guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                return false
            }

            for slot in 0..<perTableBlock {
                let record = FSObject(
                    reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                )

                guard record.standing == .live, record.kind == .file,
                      record.fits(plan)
                else { continue }

                for run in 0..<Int(record.extents) {
                    let extent = record.runs[run]

                    for block in extent.start..<(extent.start + extent.count) {
                        switch readDataBlock(block, into: dataBuffer) {
                            case .ok     : continue
                            case .damaged: found(&findings.damagedData)
                            default      : return false
                        }
                    }
                }
            }
        }

        return true
    }


    /// One bitmap block's worth of the map being built.
    func truthPage(_ map: UInt32) -> UnsafeMutableRawPointer {
        arenaBuffer.advanced(by: Int(map) * Int(FSLayout.blockSize))
    }


    /// The block map as the object table says it should be, in the arena.
    ///
    /// `fits` is asked here and not only at `object`, because this loop reads
    /// records straight out of the table: believing one whose runs point at the
    /// bitmap would mean rebuilding the map out of the map. And it is asked
    /// *before* the free-slot skip, because a kind byte this format never writes
    /// arrives clamped to `.free` - so the skip used to discard precisely the
    /// records worth refusing over.
    private mutating func buildTruth(
        _ findings: inout Findings,
        _ census  : inout Census
    ) -> Bool {

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        arenaBuffer.initializeMemory(
            as: UInt8.self, repeating: 0,
            count: Int(plan.bitmapBlocks) * Int(FSLayout.blockSize)
        )

        // Everything before the data region belongs to the file system itself
        // and is used by definition.
        markTruth(from: 0, count: plan.dataStart)

        for table in 0..<plan.tableBlocks {
            guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                return false
            }

              for slot in 0..<perTableBlock {
                    let record = FSObject(
                        reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                    )

                    let index = table * UInt32(perTableBlock) + UInt32(slot)

                    guard record.fits(plan) else {
                        found(&findings.impossible)
                        hold()
                        continue
                    }

                    guard record.standing == .live else { continue }

                    if index != FSLayout.rootObject, record.parent == index {
                        found(&findings.selfParented)

                        // A chain with no end, and nothing derives the way out.
                        hold()
                    }

                    census.owned += UInt64(record.blocks)

                    if record.kind == .container {
                        count(container: index, using: record.used, into: &census)
                    }

                    for run in 0..<Int(record.extents) {
                        let extent = record.runs[run]

                        // Bits already set are blocks something else claimed first.
                        let twice = markTruth(from: extent.start, count: extent.count)
                        if twice > 0 {
                            found(&findings.claimedTwice, by: twice)
                            hold()
                        }
                    }
              }
        }

        return true
    }


    /// Puts a live container into the census, ascending because the table is
    /// walked in order, and past `FSLayout.maxContainers` only says so.
    private func count(
        container index: UInt32,
        using       used: UInt32,
        into      census: inout Census
    ) {
        census.charged += UInt64(used)

        guard census.containers < FSLayout.maxContainers else {
            census.tooManyContainers = true
            return
        }

        tallyBuffer.storeBytes(of: index, toByteOffset: census.containers * 4, as: UInt32.self)
        dataBuffer.storeBytes(of: used, toByteOffset: census.containers * 4, as: UInt32.self)
        census.containers += 1
    }


    /// Sets `count` bits of the map being built from `start`, a word at a time,
    /// and says how many were set already.
    ///
    /// The runs were asked by `fits` to end inside the disk, so every bit lands
    /// in a bitmap block the arena holds.
    @discardableResult
    private func markTruth(from start: UInt32, count: UInt32) -> UInt32 {

        let per   = Self.blocksPerBitmapBlock
        var done  = UInt64(0)
        var twice = UInt32(0)

        while done < UInt64(count) {
            let block  = UInt64(start) + done
            let inside = Int(block % per)
            let width  = Int(min(UInt64(count) - done, per - UInt64(inside)))
            let page   = truthPage(UInt32(block / per))

            twice += UInt32(width - FSBitmap.clearCount(page, from: inside, count: width))
            FSBitmap.set(page, from: inside, count: width, used: true)

            done += UInt64(width)
        }

        return twice
    }


    /// Every name in every folder, against what it points at.
    ///
    /// One question per entry, and it answers three: looking the entry's own name
    /// up in its own folder has to come back with the entry's own object. It does
    /// not when the target disagrees about where it lives, it does not when an
    /// earlier entry of the same name shadows this one, and the bytes may not be
    /// an entry at all.
    ///
    /// **Not through `entries`.** That is the public listing, and a listing now
    /// refuses a folder whose entry points at a slot nobody uses rather than
    /// reporting it - which is right for a client and useless for a scan, whose
    /// whole job is to count the ones a client would trip on. So the directory
    /// blocks are read here, into the accumulator page, and only `lookup` and
    /// `object` are borrowed. Three separate buffers, which is why this can walk
    /// a folder and resolve a name inside the walk.
    static var nameScrubDescriptorCapacity: Int { Int(FSLayout.blockSize) / 8 }
    var nameScrubTargetCapacity: UInt64 {
        UInt64(Self.targetBlocks(plan)) * FSLayout.blockSize * 8
    }
    static var nameScrubPassBudget: Int { 32 }

    static func nameScrubPartitions(named: Int) -> Int? {
        guard named >= 0 else { return nil }
        let capacity = nameScrubDescriptorCapacity
        guard named <= capacity * nameScrubPassBudget else { return nil }
        return named == 0 ? 0 : nameScrubPassBudget
    }

    private func nameScrubHash(_ entry: FSEntry, key: UInt64) -> UInt32 {
        var value = key ^ UInt64(entry.length)
        for index in 0..<Int(entry.length) {
            value ^= UInt64(entry.name[index])
            value &*= 0x100000001B3
            value ^= value >> 29
        }
        value ^= value >> 32
        return UInt32(truncatingIfNeeded: value)
    }

    private func sameName(_ left: FSEntry, _ right: FSEntry) -> Bool {
        guard left.length == right.length else { return false }
        for index in 0..<Int(left.length) where left.name[index] != right.name[index] {
            return false
        }
        return true
    }

    private mutating func markNameScrubTarget(_ object: UInt32) -> Bool {
        let byte = Int(object / 8)
        let mask = UInt8(1) << UInt8(object % 8)
        let previous = targetBuffer.loadUnaligned(fromByteOffset: byte, as: UInt8.self)
        targetBuffer.storeBytes(of: previous | mask, toByteOffset: byte, as: UInt8.self)
        return previous & mask != 0
    }

    private mutating func nameScrubEntry(_ ordinal: UInt32, in record: FSObject) -> FSEntry? {
        let perBlock = UInt32(Self.entriesPerBlock)
        var blockOffset = ordinal / perBlock
        let slot = Int(ordinal % perBlock)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]
            if blockOffset < extent.count {
                guard readBlock(extent.start + blockOffset, into: dataBuffer) == .ok else {
                    return nil
                }
                return FSEntry(
                    reading: dataBuffer.advanced(by: slot * Int(FSLayout.entrySize))
                )
            }
            blockOffset -= extent.count
        }

        return nil
    }

    private mutating func scanNamePartition(
        _ record: FSObject,
        partition: Int,
        partitions: Int,
        key: UInt64,
        findings: inout Findings
    ) -> Bool {
        let capacity = Self.nameScrubDescriptorCapacity
        scrubBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))

        var descriptors = 0
        var ordinal: UInt32 = 0

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                guard readBlock(block, into: tallyBuffer) == .ok else { return false }

                for slot in 0..<Int(Self.entriesPerBlock) {
                    guard ordinal < UInt32.max else {
                        findings.nameScrubState = .budgetExhausted
                        return false
                    }

                    let entry = FSEntry(
                        reading: tallyBuffer.advanced(by: slot * Int(FSLayout.entrySize))
                    )
                    ordinal += 1

                    guard entry.standing == .named else { continue }

                    let hash = nameScrubHash(entry, key: key)
                    guard Int(hash % UInt32(partitions)) == partition else { continue }

                    var duplicate = false
                    for descriptor in 0..<descriptors {
                        let offset = descriptor * 8
                        guard scrubBuffer.loadUnaligned(
                            fromByteOffset: offset, as: UInt32.self
                        ) == hash else { continue }

                        let earlierOrdinal = scrubBuffer.loadUnaligned(
                            fromByteOffset: offset + 4, as: UInt32.self
                        )
                        guard let earlier = nameScrubEntry(earlierOrdinal, in: record),
                              earlier.standing == .named
                        else {
                            findings.nameScrubState = .budgetExhausted
                            return false
                        }

                        if sameName(earlier, entry) {
                            duplicate = true
                            break
                        }
                    }

                    if duplicate {
                        found(&findings.duplicateNames)
                        hold()
                        continue
                    }

                    guard descriptors < capacity else {
                        findings.nameScrubState = .budgetExhausted
                        return false
                    }

                    let offset = descriptors * 8
                    scrubBuffer.storeBytes(of: hash, toByteOffset: offset, as: UInt32.self)
                    scrubBuffer.storeBytes(of: ordinal - 1, toByteOffset: offset + 4, as: UInt32.self)
                    descriptors += 1
                }
            }
        }

        return true
    }

    mutating func scanNames(_ findings: inout Findings) -> Bool {
        guard UInt64(plan.objectCount) <= nameScrubTargetCapacity else {
            findings.nameScrubState = .budgetExhausted
            return false
        }

        targetBuffer.initializeMemory(
            as: UInt8.self, repeating: 0,
            count: Self.targetBlocks(plan) * Int(FSLayout.blockSize)
        )
        let key = superblockGeneration &* 0x9E3779B97F4A7C15
            ^ mutations

        // A table block held in the arena while its folders are walked: asking
        // the door per record copied a whole block per object.
        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)
        let held          = truthPage(0)

        for table in 0..<plan.tableBlocks {
            guard readBlock(plan.tableStart + table, into: held) == .ok else { return false }

            for slot in 0..<perTableBlock {
                let record = FSObject(reading: held.advanced(by: slot * Int(FSLayout.objectSize)))
                let index  = table * UInt32(perTableBlock) + UInt32(slot)

                // The census before this counted and held whatever is not a record.
                guard record.fits(plan), record.standing == .live, record.kind != .file else {
                    continue
                }

                var named = 0
                for run in 0..<Int(record.extents) {
                    let extent = record.runs[run]

                    for block in extent.start..<(extent.start + extent.count) {
                        guard readBlock(block, into: tallyBuffer) == .ok else { return false }

                        for slot in 0..<Int(Self.entriesPerBlock) {
                            let entry = FSEntry(
                                reading: tallyBuffer.advanced(by: slot * Int(FSLayout.entrySize))
                            )

                            switch entry.standing {
                                case .free:
                                    continue
                                case .impossible:
                                    found(&findings.brokenEntries)
                                    hold()
                                case .named:
                                    guard named < Int.max else {
                                        findings.nameScrubState = .budgetExhausted
                                        return false
                                    }
                                    named += 1

                                    switch readObject(entry.object) {
                                        case .live(let target):
                                            guard target.parent == index else {
                                                found(&findings.strayNames)
                                                hold()
                                                continue
                                            }
                                            if markNameScrubTarget(entry.object) {
                                                found(&findings.duplicateTargets)
                                                hold()
                                            }
                                        case .free, .outside, .corrupt:
                                            found(&findings.strayNames)
                                            hold()
                                        case .failed:
                                            return false
                                    }
                            }
                        }
                    }
                }

                guard let partitions = Self.nameScrubPartitions(named: named) else {
                    findings.nameScrubState = .budgetExhausted
                    return false
                }

                for partition in 0..<partitions {
                    guard scanNamePartition(
                        record,
                        partition: partition,
                        partitions: partitions,
                        key: key,
                        findings: &findings
                    ) else { return false }
                }
            }
        }

        return true
    }




    /// Every container's room against what is actually charged to it: one pass
    /// over the object table, after a census.
    ///
    /// The census found the containers, ascending because that is the order the
    /// table is walked in, and left them in the accumulator page. This pass adds
    /// up what every live record is charged to, by looking its container up in
    /// that index - a binary search of ten comparisons rather than a pass of the
    /// table. Then the counts are compared against what each container says
    /// about itself. It used to find the containers with a pass of its own.
    ///
    /// Reporting or mending. A scan reports a container whose room does not add
    /// up and holds the volume still: a volume that was not interrupted and does
    /// not add up is damaged. A dirty mount mends instead, each correction its
    /// own transaction, because a container's `used` derived from the records is
    /// right whatever the other containers say.
    ///
    /// The data page holds the counts, a thousand and twenty-four of them, which
    /// is `FSLayout.maxContainers`.
    mutating func roomWalk(
        _ findings: inout Findings,
        census    : Census,
        mending   : Bool
    ) -> Bool {

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        // Said out loud rather than checked in pieces. See
        // `FSLayout.maxContainers`.
        guard !census.tooManyContainers else {
            findings.tooManyContainers = true
            return true
        }

        let containers = census.containers

        dataBuffer.initializeMemory(
            as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize)
        )

        // What is charged to each of them.
        for table in 0..<plan.tableBlocks {
            guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                return false
            }

            for slot in 0..<perTableBlock {
                let record = FSObject(
                    reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                )

                guard record.fits(plan), record.standing == .live else { continue }

                let index = table * UInt32(perTableBlock) + UInt32(slot)

                // A container is charged to itself, which is what makes this one
                // rule rather than two.
                let place = record.kind == .container ? index : record.container

                guard let at = position(of: place, among: containers) else {
                    // No disk this build wrote has one, and there is no third
                    // account to derive the right answer from.
                    found(&findings.strayCharges)
                    hold()
                    continue
                }

                let held = dataBuffer.loadUnaligned(fromByteOffset: at * 4, as: UInt32.self)

                // Checked, because the numbers come off a disk: a table of
                // records that between them claim more blocks than the counter
                // holds is a table this must refuse rather than wrap around.
                let (total, over) = held.addingReportingOverflow(record.blocks)
                guard !over else {
                    found(&findings.impossible)
                    return false
                }

                dataBuffer.storeBytes(of: total, toByteOffset: at * 4, as: UInt32.self)
            }
        }

        // And the comparison, container by container.
        for at in 0..<containers {
            let index = tallyBuffer.loadUnaligned(fromByteOffset: at * 4, as: UInt32.self)
            let counted = dataBuffer.loadUnaligned(fromByteOffset: at * 4, as: UInt32.self)

            guard var container = object(index),
                      container.standing == .live,
                      container.kind == .container else { continue }

            guard container.used != counted else { continue }

            found(&findings.wrongQuota)

            // Reported and held, or corrected. Which of the two depends on how
            // the volume was found, and that is the whole rule: a dirty volume
            // was interrupted, so its arithmetic is behind and recomputing it is
            // finishing what was started. A clean one was not interrupted, so a
            // number that does not add up is damage or a bug, and tidying it away
            // would be tidying away the evidence.
            guard mending else {
                hold()
                continue
            }

            container.used = counted

            guard begin() == .ok else { return false }
            guard finish(store(container, at: index)) == .ok else { return false }

            found(&findings.roomsMended)
        }

        findings.quotasChecked = !findings.tooManyContainers
        return true
    }


    /// Where `container` sits in the index, by binary search.
    ///
    /// Ascending because the table is walked in order, which is what makes ten
    /// comparisons enough where a scan of the index would be a thousand.
    private func position(of container: UInt32, among count: Int) -> Int? {

        var low  = 0
        var high = count - 1

        while low <= high {
            let middle = (low + high) / 2
            let value  = tallyBuffer.loadUnaligned(
                fromByteOffset: middle * 4, as: UInt32.self
            )

            if value == container { return middle }
            if value <  container { low = middle + 1 } else { high = middle - 1 }
        }

        return nil
    }


    // MARK: - Repairing

    /// Gives back the blocks a scan found nobody owning, and nothing else.
    ///
    /// **Not public.** The only ways in are `putRight`, which is what a dirty
    /// mount runs, and a caller inside this module that has just scanned. That is
    /// the whole answer to stale findings: there is no door through which a set of
    /// them can arrive from somewhere else, or from earlier.
    ///
    /// The ticket is checked anyway, because a door that cannot be misused and a
    /// door that is checked are not the same thing. "Nothing owns these blocks"
    /// is a claim about every record there was at one moment; a mutation since
    /// then may have written one of those owners.
    mutating func repair(_ findings: Findings) -> FSStatus {

        guard findings.generation == superblockGeneration,
              findings.mutations  == mutations
        else { return .busy }

        guard findings.repairable else { return .notFound }

        // The map rebuilt from the records, whole, before the first transaction:
        // staging later goes through the arena it is built in. See below.
        var again  = Findings()
        var census = Census()
        guard buildTruth(&again, &census) else { return .deviceFailed }

        return rewriteMap()
    }


    /// Writes the map built in the arena over the one on the disk.
    ///
    /// One transaction per bitmap block, and not one for the whole repair. Each
    /// block is rebuilt from the records alone, so each is independently true of
    /// the disk: stopping between two of them leaves a correct map for the blocks
    /// already done and the old one for the rest, which is a state the next scan
    /// puts right the same way. One transaction for all of them would be bounded
    /// by the journal instead - sixteen images - and a disk big enough to need
    /// seventeen bitmap blocks could then never be repaired at all.
    ///
    /// Each transaction stages one image, into the arena's first slot, which is
    /// the first bitmap block's rebuilt page. So each page is copied out before
    /// it is staged, and the page it lands on was committed already.
    private mutating func rewriteMap() -> FSStatus {

        for map in 0..<plan.bitmapBlocks {

            dataBuffer.copyMemory(from: truthPage(map), byteCount: Int(FSLayout.blockSize))

            let begun = begin()
            guard begun == .ok else { return begun }

            guard finish(
                stageStructuralBlock(plan.bitmapStart + map, from: dataBuffer)
            ) == .ok else { return .deviceFailed }
        }

        return .ok
    }


    /// Scans, and puts right what can be derived. What a dirty mount runs.
    ///
    /// Three things, in this order, and the order is the point:
    ///
    /// 1. the journal is already replayed - `mount` does it before this is
    ///    reachable - so what is read here is the disk *after* the last
    ///    transaction, not one behind it;
    /// 2. the block map is rebuilt from the extents, which frees what nobody owns
    ///    and marks used what somebody does;
    /// 3. every container's room is rebuilt from the records that are charged to
    ///    it.
    ///
    /// Both repairs are *derivations*: the map and the room are both functions of
    /// the object table, so putting them right is recomputing them rather than
    /// choosing between two accounts. Everything that is not a derivation is left
    /// alone and holds the volume still: two records claiming one block, a record
    /// that cannot be true, a name whose target disagrees. Those are two things on
    /// the disk contradicting each other, and picking a winner is guessing with
    /// somebody's file.
    ///
    /// A device that stops answering part way through leaves the volume dirty -
    /// nothing marks it clean but `unmount` - and the findings say `complete` is
    /// false, which is what a caller reads to decide not to serve it.
    @discardableResult
    public mutating func putRight() -> Findings {

        let first = look(.blocks)
        var findings = first.findings
        guard let census = first.census else { return findings }

        // Before the repair, and whether or not the map can also be rebuilt: it
        // used to be inside the branch below.
        if findings.unfixable { quarantine() }

        // The map before the room, from the map the scan just built. The other
        // way round, the room's commit spent the ticket and the disk was refused.
        if findings.changed {
            guard findings.repairable else { return findings }
            findings.mapMended = rewriteMap() == .ok
            guard findings.mapMended else { return findings }
        }

        // Mended only on a dirty mount: on a clean one a wrong room is damage or
        // a bug, and recomputing it would tidy the evidence away.
        guard roomWalk(&findings, census: census, mending: wasDirty) else { return findings }

        if findings.unfixable { quarantine() }

        // Nothing written, so what was read is still the disk and only the names
        // are left; scanning it all again would read the table twice for nothing.
        guard findings.mapMended || findings.roomsMended > 0 else {
            findings.depth = .everything
            guard scanNames(&findings) else { return findings }

            settle(&findings)
            return findings
        }

        var verified = scan(.everything)
        verified.reclaimable  = findings.reclaimable
        verified.ownedButFree = findings.ownedButFree
        verified.claimedTwice = findings.claimedTwice
        verified.impossible   = findings.impossible
        verified.wrongQuota   = findings.wrongQuota
        verified.strayCharges = findings.strayCharges
        verified.tooManyContainers = findings.tooManyContainers
        verified.roomsMended = findings.roomsMended
        verified.mapMended  = findings.mapMended
        return verified
    }
}
