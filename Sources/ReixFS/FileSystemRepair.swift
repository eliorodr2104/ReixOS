//
//  FileSystemRepair.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Finding out whether the disk still adds up, and only then making it.
///
/// Two acts, not one, and keeping them apart is the whole of this file. A scan
/// reads and writes nothing. A repair writes, and refuses to unless the scan
/// that preceded it **finished** and found nothing that needs a person.
///
/// The coupling is not tidiness. The one repair on offer is giving back blocks
/// the map calls used that no record owns, and "no record owns them" is a claim
/// about *every* record: a scan that stopped half way through the object table
/// has not looked at the owner, and freeing on the strength of it would hand a
/// live file's blocks to the next thing that asks. So an unfinished scan repairs
/// nothing, and says so rather than reporting a number that means less than it
/// looks like.
///
/// The write order this format keeps means the ordinary residue of a crash is
/// exactly one thing - blocks marked used that nobody owns, see `barrier` - so
/// the ordinary case still puts itself right at mount. Everything else that a
/// scan can find is reported and left alone, because everything else is a
/// disagreement between two things on the disk and choosing a winner is
/// guessing with somebody's file.
///
/// Depth is a choice because cost is. `blocks` is what a crash can disturb and
/// what a dirty mount pays for; `everything` walks every directory and every
/// container's arithmetic besides, which is a great many more reads and belongs
/// to somebody asking rather than to every boot.
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
        /// Separate from `complete` because it can be skipped for a reason that
        /// is not a failure: the accumulator is a fixed table, and a disk with
        /// more containers than it holds is scanned honestly for everything else.
        public var quotasChecked = false

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
                || strayNames > 0 || duplicateNames > 0
                || selfParented > 0 || wrongQuota > 0
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
        findings.depth = depth

        guard scanBlocks(&findings) else { return findings }

        if depth == .everything {
            guard scanNames(&findings), scanRoom(&findings) else { return findings }
        }

        findings.complete = true
        return findings
    }


    /// The block map against the object table.
    ///
    /// One bitmap block at a time, and for each of them a pass over the whole
    /// object table. That is a table read per bitmap block, which on this disk is
    /// thirty-two reads, and it needs no memory beyond the two scratch blocks
    /// this type already has.
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
                    guard record.kind != .free else { continue }

                    let index = table * UInt32(perTableBlock) + UInt32(slot)

                    // Asked here and not only at `object`, because this loop
                    // reads records straight out of the table: believing one
                    // whose runs point at the bitmap would mean rebuilding the
                    // map out of the map.
                    guard record.fits(plan) else {
                        findings.impossible += 1
                        quarantine()
                        continue
                    }

                    if index != FSLayout.rootObject, record.parent == index {
                        findings.selfParented += 1
                    }

                    for run in 0..<Int(record.extents) {
                        let extent = record.runs[run]

                        for block in UInt64(extent.start)..<UInt64(extent.start + extent.count)
                        where block >= first && block < last {

                            if mark(UInt32(block)) {
                                findings.claimedTwice += 1
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

                findings.reclaimable  += UInt32(count(of: stored & ~truth))
                findings.ownedButFree += UInt32(count(of: truth & ~stored))
            }
        }

        return true
    }


    /// Every name in every folder, against what it points at.
    ///
    /// One question per entry, and it answers two: looking the entry's own name
    /// up in its own folder has to come back with the entry's own object. It
    /// does not when the target disagrees about where it lives, and it does not
    /// when an earlier entry of the same name shadows this one - and those are
    /// exactly the two things worth finding.
    ///
    /// Object by object rather than table block by table block, because walking
    /// a folder reads records itself and would overwrite the block being walked.
    private mutating func scanNames(_ findings: inout Findings) -> Bool {

        for index in 0..<plan.objectCount {

            guard let record = object(index) else {
                // A record that could not be read is one thing; one that could
                // not be true was counted already and is not a scan failure.
                guard !corrupted else { continue }
                return false
            }

            guard record.kind != .free, record.kind != .file else { continue }

            var cursor = UInt32(0)

            while let found = entry(from: cursor, in: index) {
                cursor = found.next

                let name = found.entry.name

                let resolved = withUnsafePointer(to: name) { bytes in
                    lookup(
                        UnsafeRawPointer(bytes),
                        length: Int(found.entry.length),
                        in    : index
                    )
                }

                guard resolved != found.entry.object else { continue }

                if resolved == nil {
                    findings.strayNames += 1
                } else {
                    findings.duplicateNames += 1
                }

                quarantine()
            }
        }

        return true
    }


    /// Every container's room against what is actually charged to it.
    ///
    /// One pass over the table, accumulating into a fixed table of containers.
    /// A disk with more containers than it holds is not a failure and not a
    /// silence: `quotasChecked` comes back false and the rest of the report
    /// stands.
    private mutating func scanRoom(_ findings: inout Findings) -> Bool {

        var containers = InlineArray<32, UInt32>(repeating: 0)
        var charged    = InlineArray<32, UInt32>(repeating: 0)
        var known      = 0

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        for table in 0..<plan.tableBlocks {
            guard readBlock(plan.tableStart + table, into: metaBuffer) == .ok else {
                return false
            }

            for slot in 0..<perTableBlock {
                let record = FSObject(
                    reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                )
                guard record.kind != .free, record.fits(plan) else { continue }

                let index = table * UInt32(perTableBlock) + UInt32(slot)

                // A container is charged to itself, which is what makes this one
                // rule rather than two.
                let place = record.kind == .container ? index : record.container

                var at = -1
                for seen in 0..<known where containers[seen] == place { at = seen }

                if at < 0 {
                    guard known < 32 else { return true }   // more than the table holds

                    containers[known] = place
                    charged[known]    = 0
                    at                = known
                    known            += 1
                }

                let (total, over) = charged[at].addingReportingOverflow(record.blocks)
                guard !over else { return true }

                charged[at] = total
            }
        }

        for seen in 0..<known {
            guard let container = object(containers[seen]),
                  container.kind == .container
            else { continue }

            guard container.used != charged[seen] else { continue }

            findings.wrongQuota += 1
            quarantine()
        }

        findings.quotasChecked = true
        return true
    }


    // MARK: - Repairing

    /// Gives back the blocks a scan found nobody owning, and nothing else.
    ///
    /// Refuses unless the findings say it may: something to give back, a scan
    /// that finished, and nothing found that a person should see first. Passing
    /// findings from a different disk, or older than the last write, is the one
    /// way to misuse this - so the caller that has both is the one that calls it.
    public mutating func repair(_ findings: Findings) -> FSStatus {

        guard findings.repairable else { return .notFound }

        let perTableBlock = Int(FSLayout.blockSize / FSLayout.objectSize)

        for map in 0..<plan.bitmapBlocks {

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
                    return .deviceFailed
                }

                for slot in 0..<perTableBlock {
                    let record = FSObject(
                        reading: metaBuffer.advanced(by: slot * Int(FSLayout.objectSize))
                    )
                    guard record.kind != .free, record.fits(plan) else { continue }

                    for run in 0..<Int(record.extents) {
                        let extent = record.runs[run]

                        for block in UInt64(extent.start)..<UInt64(extent.start + extent.count)
                        where block >= first && block < last {
                            mark(UInt32(block))
                        }
                    }
                }
            }

            guard writeBlock(plan.bitmapStart + map, from: dataBuffer) == .ok else {
                return .deviceFailed
            }
        }

        return .ok
    }


    /// Scans, and puts right what is safe to put right.
    ///
    /// What a dirty mount runs. The depth is `blocks` because that is what a
    /// power cut can disturb and a mount should not pay for a walk of every
    /// directory on the disk.
    @discardableResult
    public mutating func check(_ depth: Scrub = .blocks) -> Findings {

        let findings = scan(depth)

        guard findings.repairable else { return findings }

        _ = repair(findings)

        return findings
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
