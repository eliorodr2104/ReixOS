//
//  SealTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What a clean mount believes, and the moment it stops believing it.
///
/// A clean mount no longer walks the table. It reads the seal the shutdown
/// wrote, checks it against the clean mark, reads the bitmap against the seal's
/// summaries and the root's record against the seal's checksum, and serves. So
/// every test here asks one of three things of a disk changed while it was shut
/// down: is it refused at the mount, refused on the first read of what changed,
/// or - for a seal that is not the shutdown's own - checked in full instead.
@Suite("A seal is believed while the disk still says the same")
struct SealTests {

    /// 16 MiB: one bitmap block, thirty-two table blocks.
    private static let sectors: UInt64 = 32768

    /// How many files the fixture makes, which is enough that some of them live
    /// past the root's table block.
    private static let files = 40


    private func scratch(_ sectors: UInt64 = SealTests.sectors) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512),
            alignment: 8
        )
    }

    private func named(_ index: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        let text = Array("f\(index / 10)\(index % 10)".utf8)
        text.withUnsafeBufferPointer { body(UnsafeRawPointer($0.baseAddress!), $0.count) }
    }


    /// What the fixture made, by object number.
    private struct Made {
        var files     : [UInt32] = []
        var containers: [UInt32] = []
        var folder    : UInt32   = 0
    }


    /// A disk with files, a folder and two containers on it, shut down cleanly,
    /// so it carries a seal. Each file holds one block of its own index.
    private func sealed(
        sectors: UInt64 = SealTests.sectors,
        unmount: Bool = true,
        _ body: (MemoryDisk, FSLayout.Plan, Made) -> Void
    ) {
        let disk  = MemoryDisk(sectors: sectors)
        let space = scratch(sectors)
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        var made = Made()
        let block = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
        defer { block.deallocate() }

        for which in 0..<2 {
            let name = which == 0 ? "box0" as StaticString : "box1"
            let result = fs.createContainer(
                UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                quota: 64, in: FSLayout.rootObject
            )
            guard result.status == .ok else { Issue.record("container"); return }
            made.containers.append(result.object)
        }

        let folder = "docs" as StaticString
        let result = fs.create(
            UnsafeRawPointer(folder.utf8Start), length: folder.utf8CodeUnitCount,
            kind: .folder, in: FSLayout.rootObject
        )
        guard result.status == .ok else { Issue.record("folder"); return }
        made.folder = result.object

        for index in 0..<Self.files {
            var object: UInt32? = nil
            named(index) { pointer, length in
                let made = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject)
                if made.status == .ok { object = made.object }
            }
            guard let object else { Issue.record("file \(index)"); return }

            block.initializeMemory(as: UInt8.self, repeating: UInt8(index), count: Int(FSLayout.blockSize))
            guard fs.write(object, at: 0, from: block, count: FSLayout.blockSize).status == .ok else {
                Issue.record("write \(index)")
                return
            }
            made.files.append(object)
        }

        #expect(made.files.last! >= UInt32(FSLayout.blockSize / FSLayout.objectSize))

        if unmount { #expect(fs.unmount() == .ok) }

        body(disk, fs.plan, made)
    }


    /// Mounts `disk` with its own scratch, and says what that cost.
    private func mounting(
        _ disk: MemoryDisk,
        sectors: UInt64 = SealTests.sectors,
        _ body: (inout FileSystem<MemoryDisk>?, FSMount, Int) -> Void
    ) {
        let space = scratch(sectors)
        defer { space.deallocate() }

        let before = disk.reads
        let opened = FileSystem.mount(disk, scratch: space)
        var fs     = opened.disk

        body(&fs, opened.found, disk.reads - before)
    }


    /// What a clean mount reads when it believes the seal: both superblocks,
    /// the journal header, the seal, the bitmap and the root's table block.
    private func sealedReads(_ plan: FSLayout.Plan) -> Int {
        3 + Int(plan.sealBlocks) + Int(plan.bitmapBlocks) + 1
    }


    /// Whether the file at `object` still holds its fixture byte.
    private func intact(_ fs: inout FileSystem<MemoryDisk>, _ object: UInt32, _ index: Int) -> Bool {
        let block = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
        defer { block.deallocate() }

        guard fs.read(object, at: 0, into: block, count: FSLayout.blockSize).bytes == FSLayout.blockSize else {
            return false
        }
        return block.load(fromByteOffset: 100, as: UInt8.self) == UInt8(index)
    }


    // MARK: - Believed

    @Test("a clean mount reads the seal and the bitmap, and nothing that grows with the table")
    func cleanMountReadsNoTable() {
        // 64 MiB, so the table is a hundred and twenty-eight blocks and a walk
        // of it could not hide inside the count.
        let sectors: UInt64 = 131072

        sealed(sectors: sectors) { disk, plan, made in
            #expect(sealedReads(plan) < Int(plan.tableBlocks))

            mounting(disk, sectors: sectors) { fs, found, reads in
                guard var fs else { Issue.record("not served: \(found)"); return }

                #expect(!fs.wasDirty)
                #expect(reads == sealedReads(plan))
                #expect(fs.sumsKnown)

                for (index, object) in made.files.enumerated() {
                    #expect(intact(&fs, object, index), "file \(index)")
                }
            }
        }
    }


    @Test("the seal carries the quota index, so the first container after it walks nothing")
    func sealCarriesTheContainers() {
        sealed { disk, plan, made in
            mounting(disk) { fs, _, _ in
                guard var fs else { Issue.record("not served"); return }

                #expect(fs.containerCount == made.containers.count + 1)

                let before = disk.reads
                let name = "box2" as StaticString
                #expect(fs.createContainer(
                    UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                    quota: 1, in: FSLayout.rootObject
                ).status == .ok)

                // The admission count came from the seal: a walk would read the
                // whole table.
                #expect(disk.reads - before < Int(plan.tableBlocks))
            }
        }
    }


    @Test("every seal survives the next clean shutdown, and the one after")
    func sealsChain() {
        sealed { disk, plan, made in
            for round in 0..<3 {
                mounting(disk) { fs, found, reads in
                    guard var fs else { Issue.record("round \(round): \(found)"); return }
                    #expect(reads == sealedReads(plan), "round \(round)")
                    #expect(intact(&fs, made.files[round], round))
                    #expect(fs.unmount() == .ok)
                }
            }
        }
    }


    // MARK: - Refused at the mount

    @Test("a bitmap block changed since the seal is refused at the mount, untouched")
    func changedBitmapIsRefused() {
        // The first superblock's bit, always taken; the last block's, never; and
        // both at once, so the count is as sealed and only the checksum can tell.
        for (label, byte, flip) in [
            ("a taken block freed", 0, UInt8(0x01)),
            ("a free block taken", Int(Self.sectors / 8 / 8) - 1, UInt8(0x80)),
            ("one of each, the count unchanged", Int(Self.sectors / 8 / 8) - 1, UInt8(0x80)),
        ] {
            sealed { disk, plan, _ in
                let at = Int(plan.bitmapStart) * Int(FSLayout.blockSize) + byte
                disk.poke(disk.byte(at: at) ^ flip, at: at)

                if label.hasPrefix("one of each") {
                    let front = Int(plan.bitmapStart) * Int(FSLayout.blockSize)
                    disk.poke(disk.byte(at: front) ^ 0x01, at: front)
                }

                let writes = disk.writes
                mounting(disk) { fs, found, _ in
                    #expect(fs == nil, "\(label)")
                    #expect(isCorrupt(found), "\(label): \(found)")
                }
                #expect(disk.writes == writes, "\(label): written while refused")
            }
        }
    }


    @Test("the root's table block changed since the seal is refused at the mount")
    func changedRootBlockIsRefused() {
        sealed { disk, plan, _ in
            // A byte of the root record nothing reads for meaning: the checksum
            // is over the block, not over what anybody looks at.
            let at = Int(plan.tableStart) * Int(FSLayout.blockSize) + 60
            disk.poke(disk.byte(at: at) ^ 0x01, at: at)

            let writes = disk.writes
            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
            #expect(disk.writes == writes)
        }
    }


    @Test("a mounted volume's mark names no seal, so a crash never finds one to believe")
    func mountedMarkNamesNoSeal() {
        sealed { disk, _, _ in
            mounting(disk) { fs, _, _ in
                #expect(fs != nil)

                let copies = [FSLayout.superblockA, FSLayout.superblockB].map { at in
                    disk.block(at).withUnsafeBytes { FSSuperblock(reading: $0.baseAddress!) }
                }
                let newest = copies[0].generation > copies[1].generation ? copies[0] : copies[1]

                #expect(newest.state != 0)
                #expect(newest.sealChecksum == 0)
            }
        }
    }


    @Test("a power cut during a clean mount leaves the seal or the mark, and the disk mounts")
    func powerCutDuringCleanMount() {
        let sectors: UInt64 = 4096
        var requests = 0

        crashFixture(sectors) { disk, fs, _ in
            #expect(fs.unmount() == .ok)
            let before = disk.reads + disk.writes + disk.flushes
            let space = UnsafeMutableRawPointer.allocate(
                byteCount: FileSystem<CrashDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512),
                alignment: 8
            )
            defer { space.deallocate() }
            #expect(FileSystem.mount(disk, scratch: space).disk != nil)
            requests = disk.reads + disk.writes + disk.flushes - before
        }

        for stop in 1...(requests + 1) {
            for policy in [CrashDisk.Survivors.nothing, .everything] {
                crashFixture(sectors) { disk, fs, files in
                    #expect(fs.unmount() == .ok)

                    let space = UnsafeMutableRawPointer.allocate(
                        byteCount: FileSystem<CrashDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512),
                        alignment: 8
                    )
                    defer { space.deallocate() }

                    disk.failAfter(stop)
                    _ = FileSystem.mount(disk, scratch: space)
                    disk.powerCut(keeping: policy)

                    let restarted = CrashDisk(restarting: disk)
                    guard var again = FileSystem.mount(restarted, scratch: space).disk else {
                        Issue.record("stop \(stop), \(policy): refused")
                        return
                    }

                    for (index, object) in files.enumerated() {
                        #expect(crashIntact(&again, object, index), "stop \(stop), \(policy): file \(index)")
                    }
                }
            }
        }
    }


    // MARK: - Refused on first use

    @Test("a table block changed since the seal is refused the first time it is read")
    func changedTableBlockIsRefusedOnRead() {
        sealed { disk, plan, made in
            let victim = made.files.last!
            let other  = made.files.first!
            #expect(victim / 32 != 0 && other / 32 == 0)

            // Its size, to something plausible: no rule about a record can see
            // it, only the checksum of the block it is in.
            let at = Int(plan.tableStart) * Int(FSLayout.blockSize)
                + Int(victim) * Int(FSLayout.objectSize) + 8
            disk.poke(UInt64(100), at: at)

            mounting(disk) { fs, found, reads in
                guard var fs else { Issue.record("refused at the mount: \(found)"); return }
                #expect(reads == sealedReads(plan))

                let writes = disk.writes

                // Untouched blocks still read: held still is not unreadable.
                #expect(intact(&fs, other, 0))
                #expect(!fs.corrupted)

                #expect(fs.object(victim) == nil)
                #expect(fs.corrupted)

                let name = "late.bin" as StaticString
                #expect(fs.create(
                    UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                    kind: .file, in: FSLayout.rootObject
                ).status == .quarantined)

                #expect(disk.writes == writes, "written after the damage was read")
            }
        }
    }


    @Test("a folder entry changed since the seal is refused on the first lookup")
    func changedEntryIsRefusedOnLookup() {
        sealed { disk, _, _ in
            // Where the root folder's first block is, from the root's own record.
            var first: UInt32 = 0
            mounting(disk) { fs, _, _ in
                guard var fs, let root = fs.object(FSLayout.rootObject) else { return }
                first = root.runs[0].start
                #expect(fs.unmount() == .ok)
            }
            guard first != 0 else { Issue.record("no root folder block"); return }

            // A letter of a name: the entry still looks like a name.
            let base = Int(first) * Int(FSLayout.blockSize)
            var slot: Int? = nil
            for index in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
                let at = base + index * Int(FSLayout.entrySize)
                if disk.byte(at: at + 4) == 3, disk.byte(at: at + 8) == UInt8(ascii: "f") { slot = at }
            }
            guard let slot else { Issue.record("no entry to damage"); return }
            disk.poke(UInt8(ascii: "g"), at: slot + 8)

            mounting(disk) { fs, found, _ in
                guard var fs else { Issue.record("refused at the mount: \(found)"); return }

                let writes = disk.writes
                named(0) { pointer, length in
                    #expect(fs.lookup(pointer, length: length, in: FSLayout.rootObject).refusal == .quarantined)
                }
                #expect(fs.corrupted)
                #expect(disk.writes == writes)
            }
        }
    }


    // MARK: - Not believed, so checked in full

    @Test("a seal region that does not checksum is not believed, and the disk is checked in full")
    func damagedSealIsCheckedInFull() {
        sealed { disk, plan, made in
            let at = Int(plan.sealStart) * Int(FSLayout.blockSize) + Int(FSLayout.sealHeader) + 2
            disk.poke(disk.byte(at: at) ^ 0x10, at: at)

            mounting(disk) { fs, found, reads in
                guard var fs else { Issue.record("a sound disk with a damaged seal: \(found)"); return }
                #expect(reads > Int(plan.tableBlocks), "the full check did not run")
                #expect(intact(&fs, made.files[3], 3))
            }
        }
    }


    @Test("a seal of another generation is not believed, however it checksums")
    func sealOfAnotherGenerationIsCheckedInFull() {
        sealed { disk, plan, _ in
            forge(disk, plan) { seal in
                let at = FSSeal.Header.generation
                seal[at] = seal[at] &+ 1
            }

            mounting(disk) { fs, found, reads in
                #expect(fs != nil, "\(found)")
                #expect(reads > Int(plan.tableBlocks), "a seal from another moment was believed")
            }
        }
    }


    @Test("a seal for another geometry is not believed")
    func sealOfAnotherShapeIsCheckedInFull() {
        for field in [FSSeal.Header.groups, FSSeal.Header.tables, FSSeal.Header.containers] {
            sealed { disk, plan, _ in
                forge(disk, plan) { seal in seal[field] = seal[field] &+ 1 }

                mounting(disk) { fs, found, reads in
                    #expect(fs != nil, "field \(field): \(found)")
                    #expect(reads > Int(plan.tableBlocks), "field \(field) was believed")
                }
            }
        }
    }


    @Test("a quota index out of order, or naming no slot, is not believed")
    func disorderedIndexIsCheckedInFull() {
        for (label, edit) in [
            ("the root not first", { (seal: inout [UInt8], at: Int) in seal[at] = 1 }),
            ("past the table", { (seal: inout [UInt8], at: Int) in seal[at + 8 + 3] = 0x7F }),
        ] {
            sealed { disk, plan, _ in
                forge(disk, plan) { seal in
                    edit(&seal, FSSeal.indexOffset(0, groups: Int(plan.bitmapBlocks), tables: Int(plan.tableBlocks)))
                }

                mounting(disk) { fs, found, reads in
                    #expect(fs != nil, "\(label): \(found)")
                    #expect(reads > Int(plan.tableBlocks), "\(label) was believed")
                }
            }
        }
    }


    @Test("a seal whose quota index and map disagree is refused at the mount")
    func indexAgainstMapIsRefused() {
        sealed { disk, plan, _ in
            forge(disk, plan) { seal in
                let at = FSSeal.indexOffset(1, groups: Int(plan.bitmapBlocks), tables: Int(plan.tableBlocks))
                seal[at + 4] = seal[at + 4] &+ 1
            }

            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("a seal whose summary disagrees with its own bitmap block is refused at the mount")
    func summaryAgainstBitmapIsRefused() {
        sealed { disk, plan, _ in
            // The count, not the checksum: the block still checksums as sealed.
            forge(disk, plan) { seal in
                let at = FSSeal.groupOffset(0) + 4
                seal[at] = seal[at] &+ 1
            }

            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("a clean mark over a journal that is not empty is checked in full")
    func cleanMarkOverJournalIsCheckedInFull() {
        sealed { disk, plan, _ in
            var header = FSJournal()
            header.state = .prepared

            var bytes = [UInt8](repeating: 0, count: Int(FSLayout.blockSize))
            bytes.withUnsafeMutableBytes { header.write(to: $0.baseAddress!) }
            disk.put(bytes, block: plan.journalHeader)

            mounting(disk) { fs, found, reads in
                #expect(fs != nil, "\(found)")
                #expect(reads > Int(plan.tableBlocks), "a seal over a journal was believed")
            }
        }
    }


    @Test("a disk shut down without a seal is checked in full, and served when sound")
    func unsealedIsCheckedInFull() {
        sealed { disk, plan, made in
            disk.unseal(plan)

            mounting(disk) { fs, found, reads in
                guard var fs else { Issue.record("\(found)"); return }
                #expect(reads > Int(plan.tableBlocks))
                #expect(intact(&fs, made.files[5], 5))
            }
        }
    }


    // MARK: - What is not sealed

    @Test("a volume that does not add up is shut down without a seal, and refused after")
    func inconsistentVolumeIsNotSealed() {
        sealed(unmount: false) { disk, _, _ in
            // Reopened so the leak is made by a file system that then shuts down.
            mounting(disk) { fs, _, _ in
                guard var fs else { Issue.record("not served"); return }

                // Blocks taken and never owned: the one thing a crash used to leave.
                #expect(fs.begin() == .ok)
                _ = fs.allocateRun(3)
                #expect(fs.commit() == .ok)

                #expect(fs.unmount() == .ok)
                #expect(fs.namedSeal == 0)
            }

            // Clean, unsealed, and the map does not match the table: refused, as
            // a clean disk that does not add up always was.
            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("a volume whose rooms do not add up to what its records hold is not sealed")
    func roomTotalsAreNotSealed() {
        sealed(unmount: false) { disk, plan, made in
            mounting(disk) { fs, _, _ in
                guard var fs else { Issue.record("not served"); return }

                // A container charged a block nothing holds, by a hand that keeps
                // the checksums right: a bug, not rot.
                let at = Int(plan.tableStart) * Int(FSLayout.blockSize)
                    + Int(made.containers[0]) * Int(FSLayout.objectSize) + 36
                disk.poke(UInt32(disk.byte(at: at)) + 1, at: at)
                fs.believeMedium()
                #expect(fs.scan(.blocks).complete)

                #expect(fs.unmount() == .ok)
                #expect(fs.namedSeal == 0)
            }

            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("rooms wrong in ways that cancel out are found at shutdown, and refused after")
    func compensatingRoomsAreNotSealed() {
        sealed(unmount: false) { disk, plan, made in
            mounting(disk) { fs, _, _ in
                guard var fs else { Issue.record("not served"); return }

                // Something in the second container, so it has room to lose.
                let name = "held.bin" as StaticString
                let file = fs.create(
                    UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                    kind: .file, in: made.containers[1]
                )
                guard file.status == .ok else { Issue.record("file"); return }

                // One block more in one room and one less in the other, by a hand
                // that keeps every checksum right: the totals still agree.
                let first  = Int(plan.tableStart) * Int(FSLayout.blockSize)
                    + Int(made.containers[0]) * Int(FSLayout.objectSize) + 36
                let second = Int(plan.tableStart) * Int(FSLayout.blockSize)
                    + Int(made.containers[1]) * Int(FSLayout.objectSize) + 36
                #expect(disk.byte(at: second) > 0)

                disk.poke(UInt32(disk.byte(at: first)) + 1, at: first)
                disk.poke(UInt32(disk.byte(at: second)) - 1, at: second)
                fs.believeMedium()
                #expect(fs.scan(.blocks).complete)

                #expect(fs.unmount() == .ok)
                #expect(fs.namedSeal == 0)
            }

            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("a duplicate name is found at shutdown, and refused after")
    func duplicateNameIsNotSealed() {
        sealed(unmount: false) { disk, _, made in
            mounting(disk) { fs, _, _ in
                guard var fs else { Issue.record("not served"); return }

                for name in ["a.txt", "b.txt"] as [StaticString] {
                    #expect(fs.create(
                        UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                        kind: .file, in: made.folder
                    ).status == .ok)
                }
                guard let folder = fs.object(made.folder) else { return }

                // The second name made the first's, check and all.
                let base = Int(folder.runs[0].start) * Int(FSLayout.blockSize)
                for slot in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
                    let at = base + slot * Int(FSLayout.entrySize)
                    guard disk.byte(at: at + 4) == 5, disk.byte(at: at + 8) == UInt8(ascii: "b") else { continue }
                    disk.poke(UInt8(ascii: "a"), at: at + 8)
                    disk.stampEntry(at: at)
                }

                #expect(fs.unmount() == .ok)
                #expect(fs.namedSeal == 0)
            }

            mounting(disk) { fs, found, _ in
                #expect(fs == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("a volume held still is not sealed, and stays marked mounted")
    func heldVolumeIsNotSealed() {
        sealed(unmount: false) { disk, _, _ in
            mounting(disk) { fs, _, _ in
                guard var fs else { Issue.record("not served"); return }
                fs.quarantine()

                let writes = disk.writes
                #expect(fs.unmount() == .quarantined)
                #expect(disk.writes == writes)
            }

            mounting(disk) { fs, found, _ in
                #expect(fs?.wasDirty == true, "\(found)")
            }
        }
    }


    // MARK: - Power cuts

    @Test("a power cut anywhere in a sealing shutdown leaves a disk that mounts whole")
    func powerCutWhileSealing() {
        // 2 MiB, so an unmount is a handful of requests and every one of them can
        // be the last.
        let sectors: UInt64 = 4096
        var requests = 0

        crashFixture(sectors) { disk, fs, _ in
            let before = disk.reads + disk.writes + disk.flushes
            #expect(fs.unmount() == .ok)
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 3)

        let policies: [CrashDisk.Survivors] = [
            .nothing, .everything, .forwardPrefix(1), .reversePrefix(1), .permuted(7),
        ]

        var sealedMounts = 0
        var recovered    = 0

        for stop in 1...(requests + 1) {
            for policy in policies {
                crashFixture(sectors) { disk, fs, files in
                    disk.failAfter(stop)
                    _ = fs.unmount()
                    disk.powerCut(keeping: policy)

                    let restarted = CrashDisk(restarting: disk)
                    let space = UnsafeMutableRawPointer.allocate(
                        byteCount: FileSystem<CrashDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512),
                        alignment: 8
                    )
                    defer { space.deallocate() }

                    let before = restarted.reads
                    let opened = FileSystem.mount(restarted, scratch: space)
                    guard var again = opened.disk else {
                        Issue.record("stop \(stop), \(policy): refused, \(opened.found)")
                        return
                    }

                    // A clean mark is only ever written over a seal already on the
                    // medium, so a mount that finds one believes its seal.
                    if again.wasDirty {
                        recovered += 1
                    } else {
                        #expect(restarted.reads - before == sealedReads(again.plan),
                                "stop \(stop), \(policy): a clean mark without its seal")
                        sealedMounts += 1
                    }

                    for (index, object) in files.enumerated() {
                        #expect(crashIntact(&again, object, index), "stop \(stop), \(policy): file \(index)")
                    }
                    #expect(again.scan(.everything).safeToServe, "stop \(stop), \(policy)")
                }
            }
        }

        // Both ends were reached: a cut early leaves the mark, the last stop is a
        // whole shutdown and its seal is believed.
        #expect(recovered > 0)
        #expect(sealedMounts > 0)
    }


    // MARK: - Helpers

    /// A formatted CrashDisk with three one-block files, everything durable.
    private func crashFixture(
        _ sectors: UInt64,
        _ body: (CrashDisk, inout FileSystem<CrashDisk>, [UInt32]) -> Void
    ) {
        let disk  = CrashDisk(sectors: sectors)
        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<CrashDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512),
            alignment: 8
        )
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        let block = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
        defer { block.deallocate() }

        var files: [UInt32] = []
        for index in 0..<3 {
            var object: UInt32? = nil
            named(index) { pointer, length in
                let made = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject)
                if made.status == .ok { object = made.object }
            }
            guard let object else { Issue.record("file"); return }

            block.initializeMemory(as: UInt8.self, repeating: UInt8(index), count: Int(FSLayout.blockSize))
            #expect(fs.write(object, at: 0, from: block, count: FSLayout.blockSize).status == .ok)
            files.append(object)
        }

        // The data blocks are not journalled: made durable here so a cut below
        // is a cut in the shutdown and not in the fixture.
        #expect(fs.barrier() == .ok)

        body(disk, &fs, files)
    }

    private func crashIntact(_ fs: inout FileSystem<CrashDisk>, _ object: UInt32, _ index: Int) -> Bool {
        let block = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
        defer { block.deallocate() }

        guard fs.read(object, at: 0, into: block, count: FSLayout.blockSize).bytes == FSLayout.blockSize else {
            return false
        }
        return block.load(fromByteOffset: 7, as: UInt8.self) == UInt8(index)
    }


    /// Edits the seal region and then puts every checksum right: the seal's own
    /// in the clean superblock, and the superblock's. What only a hand that
    /// knows the format can do, which is the case the seal's own rules are for.
    private func forge(_ disk: MemoryDisk, _ plan: FSLayout.Plan, _ edit: (inout [UInt8]) -> Void) {
        var seal: [UInt8] = []
        for block in 0..<plan.sealBlocks { seal += disk.block(plan.sealStart + block) }

        edit(&seal)

        var sum = FSChecksum.offsetBasis
        for block in 0..<Int(plan.sealBlocks) {
            let page = Array(seal[block * Int(FSLayout.blockSize)..<(block + 1) * Int(FSLayout.blockSize)])
            disk.put(page, block: plan.sealStart + UInt32(block))
            sum = page.withUnsafeBytes {
                FSChecksum.over($0.baseAddress!, count: Int(FSLayout.blockSize), continuing: sum)
            }
        }

        // The newer of the two copies is the clean mark the mount will read.
        let copies = [FSLayout.superblockA, FSLayout.superblockB].map { at in
            (at, disk.block(at).withUnsafeBytes { FSSuperblock(reading: $0.baseAddress!) })
        }
        let (at, newest) = copies[0].1.generation > copies[1].1.generation ? copies[0] : copies[1]
        #expect(newest.state == 0 && newest.sealChecksum != 0)

        var forged = newest
        forged.sealChecksum = sum

        var bytes = [UInt8](repeating: 0, count: Int(FSLayout.blockSize))
        bytes.withUnsafeMutableBytes { forged.write(to: $0.baseAddress!) }
        disk.put(bytes, block: at)
    }
}
