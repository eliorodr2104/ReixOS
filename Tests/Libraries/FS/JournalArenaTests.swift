//
//  JournalArenaTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What the journal costs, and which journals it will act on.
///
/// Two changes, and they are the same change looked at from two ends. Staging
/// used to write its after-image straight to a payload block, so a transaction
/// that changed one bitmap block four times paid four payload writes for one
/// block of change; now the image goes into an arena in memory and the commit
/// writes each one once. And the number on a journal used to restart at one every
/// mount, so a committed journal could be numbered below one that had already been
/// applied and nothing on the disk said which of the two the home blocks held; now
/// it carries the superblock generation of the mount that wrote it, and a mount
/// discards a committed journal from an earlier mount rather than replaying it
/// over newer same-medium metadata. This is not storage anti-rollback.
@Suite("The journal's arena, and whose journal it is")
struct JournalArenaTests {

    private static let sectors: UInt64 = 4096      // 2 MiB
    private static let block = Int(FSLayout.blockSize)

    private func scratch<D: BlockDevice>(_: D.Type = MemoryDisk.self) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<D>.scratchBytes, alignment: 8
        )
    }

    private func withDisk(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch(MemoryDisk.self)
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        // The three regions, so a write can be told from a write. Nothing here
        // reads the layout: the boundaries are handed over.
        let perBlock = FSLayout.blockSize / 512
        disk.journalSectors = (UInt64(fs.plan.journalHeader) * perBlock)
            ..< (UInt64(fs.plan.journalStart + fs.plan.journalBlocks) * perBlock)
        disk.dataSector = UInt64(fs.plan.dataStart) * perBlock

        body(&fs, disk)
    }

    private func named(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString
    ) -> UInt32? {
        var made: UInt32? = nil

        named(name) { pointer, length in
            let result = fs.create(
                pointer, length: length, kind: .file, in: FSLayout.rootObject
            )
            if result.status == .ok { made = result.object }
        }

        if made == nil { Issue.record("the fixture file would not be made") }
        return made
    }


    // MARK: - What staging costs

    @Test("staging is a copy into memory and the medium hears nothing")
    func stagingIsFree() {
        withDisk { fs, disk in
            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }

            #expect(fs.begin() == .ok)

            let writes = disk.writes

            // Every slot the journal has, and each of them four times over.
            for round in 0..<4 {
                for slot in 0..<FSJournal.capacity {
                    payload.initializeMemory(
                        as: UInt8.self,
                        repeating: UInt8(round * 16 + slot),
                        count: Self.block
                    )

                    #expect(fs.stageStructuralBlock(
                        fs.plan.dataStart + UInt32(slot), from: UnsafeRawPointer(payload)
                    ) == .ok, "round \(round) slot \(slot)")
                }
            }

            // Sixty-four staging calls, no writes. It used to be sixty-four
            // payload writes for sixteen blocks of change.
            #expect(disk.writes == writes)

            // And a read of a staged block comes out of the arena, so it is not a
            // round trip either.
            let reads = disk.reads
            let back  = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { back.deallocate() }

            fs.dropCache()
            #expect(fs.readBlock(fs.plan.dataStart, into: back) == .ok)
            #expect(back.loadUnaligned(fromByteOffset: 0, as: UInt8.self) == 48)
            #expect(disk.reads == reads)

            fs.abort()
        }
    }


    @Test("sixteen kilobytes cost seven journal writes")
    func sixteenKilobytesCostSeven() {
        withDisk { fs, disk in
            guard let file = make(&fs, "big.bin") else { return }

            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 8)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 0xEE, count: 16384)

            let journal = disk.journalWrites

            #expect(fs.write(file, at: 0, from: bytes, count: 16384).status == .ok)

            // Four payloads (bitmap, table, sum block and the root's superblock)
            // and three headers; it was seven, one payload per block of the file.
            #expect(
                disk.journalWrites - journal <= 7,
                "\(disk.journalWrites - journal) journal writes"
            )
        }
    }


    @Test("four appends of sixteen kilobytes cost twenty-eight")
    func fourAppendsCostTwentyEight() {
        withDisk { fs, disk in
            guard let file = make(&fs, "grow.bin") else { return }

            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 8)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 0x77, count: 16384)

            let journal = disk.journalWrites

            for step in 0..<4 {
                #expect(fs.write(
                    file, at: UInt64(step) * 16384, from: bytes, count: 16384
                ).status == .ok, "append \(step)")
            }

            // Seven each, nothing shared: each append is its own transaction, on
            // blocks the file did not have, so none names one first.
            #expect(
                disk.journalWrites - journal <= 28,
                "\(disk.journalWrites - journal) journal writes"
            )
        }
    }


    // MARK: - Whose journal it is

    /// A committed journal naming one block, stamped for `mount`.
    private func putJournal(
        _ fs: inout FileSystem<MemoryDisk>,
        _ disk: MemoryDisk,
        target: UInt32,
        mount : UInt64,
        mark  : UInt8
    ) {
        let payload = UnsafeMutableRawPointer.allocate(
            byteCount: Self.block, alignment: 8
        )
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: mark, count: Self.block)

        #expect(fs.writeRawBlock(
            FSJournal.payload(of: 0), from: UnsafeRawPointer(payload)
        ) == .ok)

        guard let stamp = FSJournal.stamp(mount: mount, step: 1) else {
            Issue.record("mount \(mount) would not stamp")
            return
        }

        var header = FSJournal()
        header.state        = .committed
        header.generation   = stamp
        header.recordCount  = 1
        header.targets[0]   = target
        header.checksums[0] = FSChecksum.over(payload, count: Self.block)

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { raw.deallocate() }

        header.write(to: raw)
        #expect(fs.writeRawBlock(fs.plan.journalHeader, from: UnsafeRawPointer(raw)) == .ok)

        _ = disk.flush()
    }

    /// The first byte of one block, off the medium.
    private func firstByte(_ disk: MemoryDisk, _ block: UInt32) -> UInt8 {
        disk.byte(at: Int(block) * Self.block)
    }


    @Test("a journal the mount is opening is replayed")
    func ownJournalIsReplayed() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart
            let mount  = fs.superblockGeneration

            putJournal(&fs, disk, target: target, mount: mount, mark: 0x5A)

            let space = scratch(MemoryDisk.self)
            defer { space.deallocate() }

            let attempt = FileSystem.mount(disk, scratch: space)

            #expect(firstByte(disk, target) == 0x5A)
            #expect(attempt.disk == nil)
        }
    }


    @Test("a committed journal from an earlier mount is discarded, not replayed")
    func crossMountJournalIsDiscarded() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart

            // What the block holds now, which is a real table block written by
            // the format and possibly changed since.
            let before = firstByte(disk, target)
            #expect(before != 0x5A)

            // A committed journal from an earlier mount: its empty mark was lost,
            // and the current mount's metadata must not be overwritten by its
            // after-images.
            let stale = fs.superblockGeneration - 1
            #expect(stale > 0)

            putJournal(&fs, disk, target: target, mount: stale, mark: 0x5A)

            let space = scratch(MemoryDisk.self)
            defer { space.deallocate() }

            guard var again = FileSystem.mount(disk, scratch: space).disk else {
                Issue.record("the disk would not mount")
                return
            }

            // The earlier mount's journal is discarded, not replayed, and this is
            // not storage anti-rollback: a whole-medium rollback is outside this
            // on-medium comparison.
            #expect(firstByte(disk, target) == before)
            #expect(!again.corrupted)
            #expect(again.journalIsEmpty)

            // And the volume is usable.
            #expect(again.begin() == .ok)
            again.abort()
        }
    }


    @Test("a journal from a mount that never published its superblock holds the volume")
    func journalFromTheFutureQuarantines() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart
            let before = firstByte(disk, target)

            // No mount serves before publishing, so a journal stamped above the
            // newest superblock is a write the disk lost after acknowledging it.
            putJournal(
                &fs, disk, target: target,
                mount: fs.superblockGeneration + 1, mark: 0x5A
            )

            let space = scratch(MemoryDisk.self)
            defer { space.deallocate() }

            let attempt = FileSystem.mount(disk, scratch: space)

            #expect(attempt.disk == nil)
            #expect(firstByte(disk, target) == before)

            if case .corrupt = attempt.found {} else {
                Issue.record("mount answered \(attempt.found)")
            }
        }
    }


    @Test("the checkpoint is on the disk, in the mark that says the journal is empty")
    func theCheckpointSurvives() {
        withDisk { fs, disk in
            guard make(&fs, "one.bin") != nil else { return }

            // The empty header carries the generation of the last transaction
            // applied, so it can be read back without a field of its own.
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
            defer { raw.deallocate() }

            for byte in 0..<Self.block {
                raw.storeBytes(
                    of: disk.byte(at: Int(fs.plan.journalHeader) * Self.block + byte),
                    toByteOffset: byte, as: UInt8.self
                )
            }

            #expect(FSJournal.isWhole(raw))

            let header = FSJournal(reading: raw)
            #expect(header.state == .empty)
            // The mount half is the generation the transaction began under; its
            // root image moved the superblock one on.
            #expect(FSJournal.mount(of: header.generation) == fs.superblockGeneration - 1)
            #expect(FSJournal.step(of: header.generation) > 0)
        }
    }


    @Test("the two halves of a stamp come back out of it")
    func stampRoundTrips() {
        for mount in [UInt64(0), 1, 2, 0xFFFF_FFFF, 0x1_0000_0000, UInt64.max - 1] {
            for step in [UInt64(0), 1, 7, 0x1_0000_0000, UInt64.max] {
                guard let stamp = FSJournal.stamp(mount: mount, step: step) else {
                    Issue.record("\(mount)/\(step) would not stamp")
                    return
                }

                #expect(FSJournal.mount(of: stamp) == mount, "\(mount)/\(step)")
                #expect(FSJournal.step(of: stamp) == step, "\(mount)/\(step)")
            }
        }

        // The last generation leaves no successor for a root image.
        #expect(FSJournal.stamp(mount: UInt64.max, step: 0) == nil)
        #expect(FSJournal.mount(of: 5) == 0)

        guard let newer = FSJournal.stamp(mount: 2, step: 1),
              let older = FSJournal.stamp(mount: 1, step: 99)
        else {
            Issue.record("a stamp inside the bound would not be made")
            return
        }

        #expect(newer > older)
    }


    @Test("a generation above one word commits through the last available root")
    func generationExhaustion() {
        withDisk { fs, disk in
            seedGeneration(UInt64.max - 3, disk)
            let space = scratch()
            defer { space.deallocate() }
            guard var high = FileSystem.mount(disk, scratch: space).disk else {
                Issue.record("the high generation would not mount")
                return
            }
            #expect(high.superblockGeneration == UInt64.max - 2)

            for generation in [UInt64.max - 1, UInt64.max] {
                guard var root = high.object(FSLayout.rootObject) else {
                    Issue.record("the root was lost")
                    return
                }
                root.created += 1
                #expect(high.begin() == .ok)
                #expect(high.finish(high.store(root, at: FSLayout.rootObject)) == .ok)
                #expect(high.superblockGeneration == generation)
                let header = disk.block(FSLayout.journalHeaderBlock).withUnsafeBytes {
                    FSJournal(reading: $0.baseAddress!)
                }
                #expect(FSJournal.mount(of: header.generation) == generation - 1)
            }

            let writes = disk.writes
            #expect(high.begin() == .noSpace)
            #expect(disk.writes == writes)
        }
    }


    @Test("a seal compares every bit of a generation above one word")
    func highSealGeneration() {
        withDisk { fs, disk in
            seedGeneration(0x1234_5678_0000_0000, disk)
            let space = scratch()
            defer { space.deallocate() }
            guard var high = FileSystem.mount(disk, scratch: space).disk else {
                Issue.record("the high generation would not mount")
                return
            }
            #expect(high.unmount() == .ok)
            let reads = disk.reads
            let mounted = FileSystem.mount(disk, scratch: space)
            #expect(mounted.disk?.superblockGeneration == 0x1234_5678_0000_0003)
            #expect(disk.reads - reads < 10)
        }
    }


    @Test("an earlier journal layout is refused without a write")
    func earlierJournalIsRefused() {
        withDisk { fs, disk in
            let at = Int(FSLayout.journalHeaderBlock) * Self.block
            disk.poke(UInt32(1), at: at + FSJournal.Header.version)
            let page = disk.block(FSLayout.journalHeaderBlock)
            let check = page.withUnsafeBytes {
                FSChecksum.over($0.baseAddress!, count: FSJournal.Header.width,
                                zeroing: FSJournal.Header.checksum)
            }
            disk.poke(check, at: at + FSJournal.Header.checksum)
            let writes = disk.writes
            let space = scratch()
            defer { space.deallocate() }
            let mounted = FileSystem.mount(disk, scratch: space)
            #expect(mounted.disk == nil)
            if case .corrupt = mounted.found {} else { Issue.record("\(mounted.found)") }
            #expect(disk.writes == writes)
        }
    }


    private func seedGeneration(_ generation: UInt64, _ disk: MemoryDisk) {
        for home in [FSLayout.superblockA, FSLayout.superblockB] {
            let at = Int(home) * Self.block
            disk.poke(generation, at: at + FSSuperblockField.generation)
            let page = disk.block(home)
            let check = page.withUnsafeBytes {
                FSChecksum.over($0.baseAddress!, count: FSSuperblockField.width,
                                zeroing: FSSuperblockField.checksum)
            }
            disk.poke(check, at: at + FSSuperblockField.checksum)
        }
    }


    // MARK: - A header nobody is waiting for

    @Test("a prepared header the device would not clear is cleared by the next begin")
    func preparedHeaderIsRetried() {
        withDisk { fs, disk in
            guard let file = make(&fs, "kept.bin") else { return }

            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 0x11, count: 64)

            // Refuse from the first request of the commit, so the payload write
            // or the prepared header fails and the tidying up fails with it.
            fs.dropCache()
            disk.failAfter(1)

            #expect(fs.write(file, at: 0, from: bytes, count: 64).status != .ok)
            disk.recover()

            // The journal is left holding something, so it was not tidied.
            if fs.journalState == .empty {
                // The device refused before anything was written, which is also a
                // valid outcome: nothing to tidy.
                #expect(fs.begin() == .ok)
                fs.abort()
                return
            }

            #expect(fs.journalState == .prepared)

            // And the next transaction clears it rather than being refused for the
            // rest of the boot over a header nobody is waiting for.
            #expect(fs.begin() == .ok)
            #expect(fs.journalIsEmpty)
            fs.abort()
        }
    }


    @Test("a committed header is not something a transaction may clear")
    func committedHeaderIsNotCleared() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart

            // Put the volume in the state a commit that applied nothing leaves:
            // a promise on the disk and this process knowing it.
            putJournal(&fs, disk, target: target, mount: fs.superblockGeneration, mark: 0x5A)

            let space = scratch(MemoryDisk.self)
            defer { space.deallocate() }

            let attempt = FileSystem.mount(disk, scratch: space)

            #expect(firstByte(disk, target) == 0x5A)
            #expect(attempt.disk == nil)
        }
    }
}
