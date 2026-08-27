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
        /// `maxContainersV02`.
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

    /// Reads the disk and says what it found. Writes nothing, ever.
    public mutating func scan(_ depth: Scrub = .blocks) -> Findings {

        var findings = Findings()
        findings.depth      = depth
        findings.generation = superblockGeneration
        findings.mutations  = mutations

        guard scanBlocks(&findings) else { return findings }

        if depth == .everything {
            guard scanNames(&findings), scanRoom(&findings) else { return findings }
        }

        findings.complete = true
        findings.safeToServe = findings.quotasChecked && !findings.tooManyContainers
            && !findings.unfixable && !findings.changed
        return findings
    }


    /// The block map against the object table.
    ///
    /// One bitmap block at a time, and for each of them a pass over the whole
    /// object table. That is a table read per bitmap block, which on this disk is
    /// thirty-two reads, and it needs no memory beyond the two scratch blocks
    /// this type already has.
    ///
    /// `fits` is asked here and not only at `object`, because this loop reads
    /// records straight out of the table: believing one whose runs point at the
    /// bitmap would mean rebuilding the map out of the map. And it is asked
    /// *before* the free-slot skip, because a kind byte this format never writes
    /// arrives clamped to `.free` - so the skip used to discard precisely the
    /// records worth refusing over.
    private mutating func scanBlocks(_ findings: inout Findings) -> Bool {

        let perBitmapBlock = Self.blocksPerBitmapBlock
        let perTableBlock  = Int(FSLayout.blockSize / FSLayout.objectSize)

        for map in 0..<plan.bitmapBlocks {

            let first = UInt64(map) * perBitmapBlock
            let last  = first + perBitmapBlock

            dataBuffer.initializeMemory(
                as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize)
            )

            // Everything before the data region belongs to the file system
            // itself and is used by definition.
            for block in 0..<UInt64(plan.dataStart) where block >= first && block < last {
                mark(UInt32(block))
            }

            for table in 0..<plan.tableBlocks {
                guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                    return false
                }

                for slot in 0..<perTableBlock {
                    let record = FSObject(
                        reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                    )

                    let index = table * UInt32(perTableBlock) + UInt32(slot)

                    // Asked here and not only at `object`, and asked before the
                    // free-slot skip. See the doc above.
                    guard record.fits(plan) else {
                        found(&findings.impossible)
                        quarantine()
                        continue
                    }

                    guard record.standing == .live else { continue }

                    if index != FSLayout.rootObject, record.parent == index {
                        found(&findings.selfParented)

                        // A chain with no end, and nothing derives the way out.
                        quarantine()
                    }

                    for run in 0..<Int(record.extents) {
                        let extent = record.runs[run]

                        for block in UInt64(extent.start)..<UInt64(extent.start + extent.count)
                        where block >= first && block < last {

                            if mark(UInt32(block)) {
                                found(&findings.claimedTwice)
                                quarantine()
                            }
                        }
                    }
                }
            }

            guard readBlock(plan.bitmapStart + map, into: metaBuffer) == .ok else {
                return false
            }

            for byte in 0..<Int(FSLayout.blockSize) {
                let truth  = dataBuffer.loadUnaligned(fromByteOffset: byte, as: UInt8.self)
                let stored = metaBuffer.loadUnaligned(fromByteOffset: byte, as: UInt8.self)

                guard truth != stored else { continue }

                found(&findings.reclaimable,  by: UInt32(count(of: stored & ~truth)))
                found(&findings.ownedButFree, by: UInt32(count(of: truth & ~stored)))
            }
        }

        return true
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
    static var nameScrubTargetCapacity: UInt32 { UInt32(FSLayout.blockSize * 8) }
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
                        quarantine()
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

    private mutating func scanNames(_ findings: inout Findings) -> Bool {
        guard plan.objectCount <= Self.nameScrubTargetCapacity else {
            findings.nameScrubState = .budgetExhausted
            return false
        }

        targetBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        let key = superblockGeneration &* 0x9E3779B97F4A7C15
            ^ mutations

        for index in 0..<plan.objectCount {
            let record: FSObject
            switch readObject(index) {
                case .live(let value):
                    record = value
                case .free:
                    continue
                case .outside:
                    findings.nameScrubState = .budgetExhausted
                    return false
                case .failed:
                    return false
                case .corrupt:
                    continue
            }

            guard record.kind != .file else { continue }

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
                                quarantine()
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
                                            quarantine()
                                            continue
                                        }
                                        if markNameScrubTarget(entry.object) {
                                            found(&findings.duplicateTargets)
                                            quarantine()
                                        }
                                    case .free, .outside, .corrupt:
                                        found(&findings.strayNames)
                                        quarantine()
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

        return true
    }


    /// How many containers this version of the format keeps an index of.
    ///
    /// One page of counters, so a thousand and twenty-four. It is a *bound* and
    /// not a window: the walk below reads the object table twice however many
    /// containers there are, and a disk with more than this many is reported
    /// rather than checked in pieces.
    ///
    /// It used to be a window, and that was the mistake. A pass over the whole
    /// object table per window meant the thousand and twenty-fifth container
    /// bought a second pass, and on a large disk a pass is the whole table: the
    /// room walk went from one table read per block to as many as there are
    /// windows. Measured, the step was visible; see `ScaleTests`.
    ///
    /// Past this the answer is a persistent quota index, which is v03: a number
    /// kept up to date as blocks are charged needs no walk at all.
    static var maxContainersV02: Int { Int(FSLayout.blockSize) / 4 }


    /// Every container's room against what is actually charged to it.
    ///
    /// Writes nothing, whatever it finds, and holds the volume still when it
    /// finds a container whose room does not add up. A volume that was not
    /// interrupted and does not add up is damaged; the one that was interrupted
    /// is put right instead, by `putRight`, and that is the only place a room is
    /// ever recomputed.
    private mutating func scanRoom(_ findings: inout Findings) -> Bool {
        roomWalk(&findings, mending: false)
    }


    /// Rebuilds every container's room from the records charged to it.
    ///
    /// Each correction is its own transaction: a container's `used` derived from
    /// the records is right whatever the other containers say, so correcting one
    /// is an act that stands alone and does not have to fit in a journal beside
    /// the rest.
    private mutating func roomRebuild(_ findings: inout Findings) -> Bool {
        roomWalk(&findings, mending: true)
    }


    /// Two passes over the object table, and never more.
    ///
    /// The first finds the containers, in ascending order because that is the
    /// order the table is walked in. The second adds up what every live record is
    /// charged to, by looking its container up in that index - a binary search of
    /// ten comparisons rather than a pass of the table. Then the counts are
    /// compared against what each container says about itself.
    ///
    /// Two buffers, and both are free here: the accumulator page holds the index
    /// and the data page holds the counts. A thousand and twenty-four of each,
    /// which is `maxContainersV02`.
    private mutating func roomWalk(
        _ findings: inout Findings,
        mending   : Bool
    ) -> Bool {

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        tallyBuffer.initializeMemory(
            as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize)
        )
        dataBuffer.initializeMemory(
            as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize)
        )

        // Pass one: which containers there are.
        var containers = 0

        for table in 0..<plan.tableBlocks {
            guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                return false
            }

            for slot in 0..<perTableBlock {
                let record = FSObject(
                    reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                )

                guard record.fits(plan), record.standing == .live,
                      record.kind == .container else { continue }

                guard containers < Self.maxContainersV02 else {
                    // Said out loud rather than checked in pieces. See
                    // `maxContainersV02`.
                    findings.tooManyContainers = true
                    return true
                }

                let index = table * UInt32(perTableBlock) + UInt32(slot)
                tallyBuffer.storeBytes(
                    of: index, toByteOffset: containers * 4, as: UInt32.self
                )

                containers += 1
            }
        }

        // Pass two: what is charged to each of them.
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
                    quarantine()
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
                quarantine()
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

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        // One transaction per bitmap block, and not one for the whole repair.
        //
        // Each block is rebuilt from the records alone, so each is independently
        // true of the disk: stopping between two of them leaves a correct map for
        // the blocks already done and the old one for the rest, which is a state
        // the next scan puts right the same way. One transaction for all of them
        // would be bounded by the journal instead - sixteen images - and a disk
        // big enough to need seventeen bitmap blocks could then never be
        // repaired at all.
        for map in 0..<plan.bitmapBlocks {

            let begun = begin()
            guard begun == .ok else { return begun }

            let first = UInt64(map) * Self.blocksPerBitmapBlock
            let last  = first + Self.blocksPerBitmapBlock

            dataBuffer.initializeMemory(
                as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize)
            )

            for block in 0..<UInt64(plan.dataStart) where block >= first && block < last {
                mark(UInt32(block))
            }

            for table in 0..<plan.tableBlocks {
                guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                    abort()
                    return .deviceFailed
                }

                for slot in 0..<perTableBlock {
                    let record = FSObject(
                        reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                    )
                    guard record.fits(plan), record.standing == .live else { continue }

                    for run in 0..<Int(record.extents) {
                        let extent = record.runs[run]

                        for block in UInt64(extent.start)..<UInt64(extent.start + extent.count)
                        where block >= first && block < last {
                            mark(UInt32(block))
                        }
                    }
                }
            }

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

        var findings = scan(.blocks)

        // The room, and only on a dirty mount. A clean volume whose containers do
        // not add up was not interrupted: something wrote a number that cannot be
        // true, and recomputing it would be tidying away the evidence of a bug or
        // of damage. So it is corruption there and a repair here.
        if wasDirty, findings.complete {
            guard roomRebuild(&findings) else { return findings }
        }

        // Before the repair, and whether or not the map can also be rebuilt: it
        // used to be inside the branch below.
        if findings.unfixable { quarantine() }

        if findings.changed {
            guard findings.repairable else { return findings }
            findings.mapMended = repair(findings) == .ok
            guard findings.mapMended else { return findings }
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


    /// Sets one block's bit in the map being built, and says whether it was
    /// already set.
    ///
    /// The answer is the double-claim detector, free of charge: the walk already
    /// visits every block every record claims, so a block visited twice is a
    /// block two records claim.
    @discardableResult
    private func mark(_ block: UInt32) -> Bool {
        let place = Self.bitmapBit(of: block)

        let byte  = dataBuffer.loadUnaligned(fromByteOffset: place.byte, as: UInt8.self)
        let taken = byte & (1 << place.bit) != 0

        dataBuffer.storeBytes(
            of: byte | (1 << place.bit), toByteOffset: place.byte, as: UInt8.self
        )

        return taken
    }


    /// How many bits are set in a byte. Eight comparisons, no table.
    private func count(of byte: UInt8) -> Int {
        var value = byte
        var total = 0

        while value != 0 {
            total += Int(value & 1)
            value >>= 1
        }

        return total
    }
}
