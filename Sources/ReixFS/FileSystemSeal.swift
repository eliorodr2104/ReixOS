//
//  FileSystemSeal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.
//

import ReixABI

/// Sealing a volume on the way out, and believing the seal on the way back in.
///
/// **The check moved, it did not go.** A clean mount used to walk the whole
/// object table, every name in every folder, and every container's room, before
/// it served a byte. Now `unmount` does that walk, and only a volume it finds
/// whole is sealed: the checksum of every bitmap, table and sum block, a summary
/// of every bitmap block, and the quota index. The next mount checks the seal
/// against the clean mark, reads the bitmap against its summaries, and serves.
///
/// What it does not read, it checks later. The seal hands every table block's
/// checksum to `sums`, and a table block read off the medium that does not
/// match is refused the first time it is read. A directory entry carries its
/// own check. So a disk that changed while it was shut down is caught at the
/// mount, for the map and the seal, or at the first read of what changed, for
/// the table and the folders. A dirty disk has no seal to believe and is
/// recovered in full, as it always was; `fs.scrub` still walks everything.
extension FileSystem {

    /// What a clean mount made of the seal.
    enum SealCheck: Equatable {

        /// The seal is the one the last shutdown wrote, and the disk agrees.
        case verified

        /// There is no seal to believe: none was written, or the region does not
        /// check out against the clean mark. Checked in full instead.
        case absent

        /// The seal is the shutdown's own, and the disk says something else.
        /// Something changed it while it was shut down.
        case contradicted

        /// The device stopped answering.
        case failed
    }


    // MARK: - Sealing

    /// Checks the whole volume, as `scan(.everything)` does, and seals it only
    /// when the check is complete and finds nothing. Answers the seal's checksum,
    /// or zero for no seal.
    ///
    /// **A sealed volume is a fully verified one.** The map against the table,
    /// every container's room against what is charged to it, and every name in
    /// every folder, so that a mount believing the seal believes no less than a
    /// mount that walked it all. The room walk reuses the census and the names
    /// are walked last, after the seal is written: they borrow the pages the
    /// seal is written from. A finding there leaves the written region unnamed.
    ///
    /// Zero is not a failure. A volume that does not add up, or one this process
    /// has stopped trusting, is shut down without a seal and checked in full by
    /// the next mount, which refuses what this found. The findings do not hold
    /// the volume here, so that the clean mark still goes down: see `scanHolds`.
    mutating func writeSeal() -> UInt32 {

        guard journalIsEmpty, !inTransaction, !corrupted, !deviceStopped, sumsKnown,
              superblockGeneration < UInt64.max
        else { return 0 }

        scanHolds = false
        defer { scanHolds = true }

        var findings = Findings()
        guard let census = scanBlocks(&findings), !corrupted,
              !findings.changed, findings.claimedTwice == 0,
              findings.impossible == 0, findings.selfParented == 0,
              !census.tooManyContainers, census.containers > 0,
              census.owned == census.charged,
              tallyBuffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == FSLayout.rootObject
        else { return 0 }

        // Every room, from the census. What it leaves in the data page is each
        // container's count, which with nothing wrong is its `used`.
        guard roomWalk(&findings, census: census, mending: false), !corrupted,
              findings.quotasChecked, findings.wrongQuota == 0,
              findings.strayCharges == 0, findings.impossible == 0
        else { return 0 }

        metaBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))

        // The generation the clean mark after this will carry.
        metaBuffer.storeBytes(of: FSSeal.magic, toByteOffset: FSSeal.Header.magic, as: UInt64.self)
        metaBuffer.storeBytes(of: superblockGeneration + 1, toByteOffset: FSSeal.Header.generation, as: UInt64.self)
        metaBuffer.storeBytes(of: plan.bitmapBlocks, toByteOffset: FSSeal.Header.groups, as: UInt32.self)
        metaBuffer.storeBytes(of: plan.tableBlocks + plan.sumBlocks, toByteOffset: FSSeal.Header.tables, as: UInt32.self)
        metaBuffer.storeBytes(of: UInt32(census.containers), toByteOffset: FSSeal.Header.containers, as: UInt32.self)

        var pen = SealPen(at: Int(FSLayout.sealHeader))

        // The map on the disk is the one just built, so its bits are counted off
        // the arena rather than read again.
        for map in 0..<plan.bitmapBlocks {
            let clear = FSBitmap.clearCount(
                truthPage(map), from: 0, count: Int(Self.blocksPerBitmapBlock)
            )

            guard put(expectedSum(of: plan.bitmapStart + map) ?? 0, &pen),
                  put(UInt32(Int(Self.blocksPerBitmapBlock) - clear), &pen)
            else { return 0 }
        }

        // The table and the sum region, which follow it.
        for table in 0..<(plan.tableBlocks + plan.sumBlocks) {
            guard put(expectedSum(of: plan.tableStart + table) ?? 0, &pen) else { return 0 }
        }

        for entry in 0..<census.containers {
            let object = tallyBuffer.loadUnaligned(fromByteOffset: entry * 4, as: UInt32.self)
            let used   = dataBuffer.loadUnaligned(fromByteOffset: entry * 4, as: UInt32.self)

            guard put(object, &pen), put(used, &pen) else { return 0 }
        }

        // The rest of the region, zero, so the checksum is over all of it.
        while pen.block < Int(plan.sealBlocks) {
            guard flush(&pen) else { return 0 }
        }

        // The names, last: a finding here leaves the region written and unnamed.
        guard scanNames(&findings), !corrupted, !findings.damaged else { return 0 }

        // On the medium before the clean mark that names it.
        guard barrier() == .ok else { return 0 }

        return pen.sum
    }


    /// Where the seal being written has got to: which block of the region is in
    /// the metadata page, how far into it, and the checksum of the blocks before.
    private struct SealPen {
        var block = 0
        var at    : Int
        var sum   = FSChecksum.offsetBasis

        init(at: Int) { self.at = at }
    }

    private mutating func put(_ value: UInt32, _ pen: inout SealPen) -> Bool {
        if pen.at == Int(FSLayout.blockSize) {
            guard flush(&pen) else { return false }
        }

        metaBuffer.storeBytes(of: value, toByteOffset: pen.at, as: UInt32.self)
        pen.at += 4
        return true
    }

    /// Writes the page out as the next block of the region and starts a clean one.
    private mutating func flush(_ pen: inout SealPen) -> Bool {
        guard pen.block < Int(plan.sealBlocks) else { return false }

        pen.sum = FSChecksum.over(metaBuffer, count: Int(FSLayout.blockSize), continuing: pen.sum)

        guard writeRawBlock(plan.sealStart + UInt32(pen.block), from: metaBuffer) == .ok else {
            return false
        }

        pen.block += 1
        pen.at     = 0
        metaBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        return true
    }


    // MARK: - Believing it

    /// Checks the seal a clean shutdown left, and the bitmap against it.
    ///
    /// Reads the seal region and every bitmap block, and one table block for the
    /// root: nothing that grows with the table. On `verified` the table blocks'
    /// checksums are in `sums` and every later read of one is checked against
    /// them; on anything else `sums` knows nothing and the mount checks in full.
    mutating func openSeal() -> SealCheck {
        let answer = readSeal()
        if answer != .verified {
            sumsKnown      = false
            sumRegionKnown = false
        }
        return answer
    }


    private mutating func readSeal() -> SealCheck {

        let named = namedSeal
        guard named != 0 else { return .absent }

        let groups = Int(plan.bitmapBlocks)
        let tables = Int(plan.tableBlocks + plan.sumBlocks)

        // The summaries are kept in the descriptor page while the bitmap is read.
        guard groups * 8 <= Int(FSLayout.blockSize) else { return .absent }

        var cursor = SealCursor()

        func word(_ offset: Int) -> UInt32? { sealWord(at: offset, &cursor) }

        guard let magicLow  = word(FSSeal.Header.magic),
              let magicHigh = word(FSSeal.Header.magic + 4),
              let genLow    = word(FSSeal.Header.generation),
              let genHigh   = word(FSSeal.Header.generation + 4),
              let sealedGroups = word(FSSeal.Header.groups),
              let sealedTables = word(FSSeal.Header.tables),
              let containers   = word(FSSeal.Header.containers)
        else { return cursor.failed ? .failed : .absent }

        let limit = min(FSLayout.maxContainers, Int(plan.objectCount))

        guard UInt64(magicHigh) << 32 | UInt64(magicLow) == FSSeal.magic,
              UInt64(genHigh) << 32 | UInt64(genLow) == superblockGeneration,
              sealedGroups == plan.bitmapBlocks, sealedTables == UInt32(tables),
              containers > 0, Int(containers) <= limit
        else { return .absent }

        for group in 0..<groups {
            guard let sum  = word(FSSeal.groupOffset(group)),
                  let used = word(FSSeal.groupOffset(group) + 4)
            else { return cursor.failed ? .failed : .absent }

            scrubBuffer.storeBytes(of: sum,  toByteOffset: group * 8,     as: UInt32.self)
            scrubBuffer.storeBytes(of: used, toByteOffset: group * 8 + 4, as: UInt32.self)
        }

        for table in 0..<tables {
            guard let sum = word(FSSeal.tableOffset(table, groups: groups)) else {
                return cursor.failed ? .failed : .absent
            }
            expect(sum, of: plan.tableStart + UInt32(table))
        }

        // Ascending, the root first, every one a slot this table has, and room
        // that adds up without wrapping.
        var charged = UInt64(0)
        var last    = UInt32(0)

        for entry in 0..<Int(containers) {
            let at = FSSeal.indexOffset(entry, groups: groups, tables: tables)

            guard let object = word(at), let used = word(at + 4) else {
                return cursor.failed ? .failed : .absent
            }

            let ordered = entry == 0 ? object == FSLayout.rootObject : object > last
            guard ordered, object < plan.objectCount else { return .absent }

            charged += UInt64(used)
            last     = object
        }

        // The rest of the region, so the checksum is over all of it.
        while cursor.loaded + 1 < Int(plan.sealBlocks) {
            guard word((cursor.loaded + 1) * Int(FSLayout.blockSize)) != nil else {
                return cursor.failed ? .failed : .absent
            }
        }

        guard cursor.loaded + 1 == Int(plan.sealBlocks), cursor.sum == named else {
            return .absent
        }

        // The seal is the shutdown's own. From here a disagreement is the disk's.
        sumsKnown = false

        // Its sum blocks' checksums are the region the superblock's root covers,
        // so the two agree with no read of the region.
        guard sumRoot().root == namedRoot else { return .contradicted }
        sumRegionKnown = true

        var used = UInt64(0)

        for group in 0..<groups {
            let at = plan.bitmapStart + UInt32(group)
            guard readBlock(at, into: metaBuffer) == .ok else { return .failed }

            let sealedSum  = scrubBuffer.loadUnaligned(fromByteOffset: group * 8,     as: UInt32.self)
            let sealedUsed = scrubBuffer.loadUnaligned(fromByteOffset: group * 8 + 4, as: UInt32.self)

            let bits  = Int(Self.blocksPerBitmapBlock)
            let count = UInt32(bits - FSBitmap.clearCount(metaBuffer, from: 0, count: bits))

            guard expectedSum(of: at) == sealedSum, count == sealedUsed else {
                return .contradicted
            }

            used += UInt64(count)
        }

        // The map, the front of the disk and the quota index are one fact.
        guard used == UInt64(plan.dataStart) + charged else { return .contradicted }

        sumsKnown = true

        switch readObject(FSLayout.rootObject) {
            case .live(let root) where root.kind == .container:
                break
            // A block that is not the one sealed reads as a refusal, and it is
            // the disk contradicting the seal rather than the device failing.
            case .failed:
                return corrupted ? .contradicted : .failed
            default:
                return .contradicted
        }

        containerCount = Int(containers)
        return .verified
    }


    /// Which block of the seal region is in the metadata page, and the checksum
    /// of every block of it read so far.
    private struct SealCursor {
        var loaded = -1
        var sum    = FSChecksum.offsetBasis
        var failed = false
    }

    /// The word at `offset` bytes into the seal region, read forwards only, or
    /// nil past the region or when the device stopped answering.
    private mutating func sealWord(at offset: Int, _ cursor: inout SealCursor) -> UInt32? {
        let block = offset / Int(FSLayout.blockSize)
        guard block < Int(plan.sealBlocks), block >= cursor.loaded else { return nil }

        while cursor.loaded < block {
            let next = UInt32(cursor.loaded + 1)

            guard readRawBlock(plan.sealStart + next, into: metaBuffer) == .ok else {
                cursor.failed = true
                return nil
            }

            cursor.sum = FSChecksum.over(
                metaBuffer, count: Int(FSLayout.blockSize), continuing: cursor.sum
            )
            cursor.loaded += 1
        }

        return metaBuffer.loadUnaligned(
            fromByteOffset: offset % Int(FSLayout.blockSize), as: UInt32.self
        )
    }
}
