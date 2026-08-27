//
//  RecoveryTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What a mount puts right, what it refuses to touch, and what a set of findings
/// is a statement about.
///
/// Three acts kept apart. A **scan** reads and holds the volume still when it
/// finds a contradiction, and writes nothing whatever it finds. **Putting right**
/// is what a dirty mount runs, and it corrects the two things that are functions
/// of the object table and nothing else: the block map and every container's
/// room. A **repair** is the writing half of that, reachable only from inside and
/// only with a ticket saying which moment it is a report about.
///
/// The room walk has one bounded page of container indices. It reaches every
/// representable v02 container and rejects an image with more than that bound;
/// it does not use a moving window that could silently omit part of the disk.
@Suite("Recovery and scrub")
struct RecoveryTests {

    /// 16 MiB: 4096 blocks and 1024 object slots, so one window covers it.
    private static let sectors: UInt64 = 32768

    /// 64 MiB: 4096 object slots, so the walk has to window four times.
    private static let wideSectors: UInt64 = 131072


    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
    }

    private func withFileSystem(
        sectors: UInt64 = RecoveryTests.sectors,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk  = MemoryDisk(sectors: sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        body(&fs, disk)
    }

    /// Mounts the disk again, which is where a mount's own recovery happens.
    private func remount(
        _ disk: MemoryDisk,
        _ body: (inout FileSystem<MemoryDisk>, FSMount) -> Void
    ) {
        let space = scratch()
        defer { space.deallocate() }

        let attempt = FileSystem.mount(disk, scratch: space)

        guard var mounted = attempt.disk else {
            Issue.record("the disk would not mount: \(attempt.found)")
            return
        }

        body(&mounted, attempt.found)
    }


    /// `c<nnnn>` as five bytes, so a fixture can make ten thousand distinct
    /// names without two of them colliding.
    private func named(_ index: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        var name = InlineArray<8, UInt8>(repeating: 0)
        name[0] = UInt8(ascii: "c")
        name[1] = UInt8(0x30 + UInt8(index / 1000 % 10))
        name[2] = UInt8(0x30 + UInt8(index / 100 % 10))
        name[3] = UInt8(0x30 + UInt8(index / 10 % 10))
        name[4] = UInt8(0x30 + UInt8(index % 10))

        name.span.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!), 5)
        }
    }


    @discardableResult
    private func container(
        _ fs: inout FileSystem<MemoryDisk>,
        _ index: Int,
        room: UInt32 = 1
    ) -> UInt32? {
        var made: UInt32? = nil

        named(index) { pointer, length in
            let result = fs.createContainer(
                pointer, length: length, quota: room, in: FSLayout.rootObject
            )
            if result.status == .ok { made = result.object }
        }

        return made
    }


    // MARK: - No limit on containers

    @Test("thirty-three containers are all checked")
    func thirtyThreeAreChecked() {
        withFileSystem { fs, _ in
            for index in 0..<33 {
                guard container(&fs, index) != nil else {
                    Issue.record("container \(index) would not be made")
                    return
                }
            }

            let findings = fs.scan(.everything)

            // The number this test is named after. The old walk gave up at
            // thirty-two and said so with a flag, which is a report about the
            // accumulator dressed up as a report about the disk.
            #expect(findings.complete)
            #expect(findings.quotasChecked)
            #expect(findings.wrongQuota == 0)
            #expect(!fs.corrupted)
        }
    }


    @Test("sixty-four containers are all checked")
    func sixtyFourAreChecked() {
        withFileSystem { fs, _ in
            for index in 0..<64 {
                guard container(&fs, index) != nil else {
                    Issue.record("container \(index) would not be made")
                    return
                }
            }

            let findings = fs.scan(.everything)

            #expect(findings.complete)
            #expect(findings.quotasChecked)
            #expect(findings.wrongQuota == 0)
            #expect(!fs.corrupted)
        }
    }


    @Test("the container ceiling refuses before a transaction writes")
    func containerCeilingStopsBeforeWrites() {
        withFileSystem { fs, disk in
            fs.containerCount = FileSystem<MemoryDisk>.maxContainersV02
            let writes = disk.writes

            named(1_024) { pointer, length in
                #expect(
                    fs.createContainer(
                        pointer, length: length, quota: 0, in: FSLayout.rootObject
                    ).status == .unsupportedCapacity
                )
            }

            #expect(disk.writes == writes)
            #expect(!fs.inTransaction)
        }
    }

    @Test("the real container limit survives remount and removal")
    func containerLimitRemountAndRemoval() {
        let disk = MemoryDisk(sectors: Self.wideSectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        let limit = FileSystem<MemoryDisk>.maxContainersV02
        for index in 0..<(limit - 1) {
            guard container(&fs, index, room: 0) != nil else {
                Issue.record("container \(index)")
                return
            }
        }

        let beforeRefusal = disk.writes
        named(limit) { pointer, length in
            #expect(fs.createContainer(
                pointer, length: length, quota: 0, in: FSLayout.rootObject
            ).status == .unsupportedCapacity)
        }
        #expect(disk.writes == beforeRefusal)

        #expect(fs.unmount() == .ok)
        remount(disk) { mounted, found in
            guard case .ok = found else { Issue.record("remount \(found)"); return }

            let beforeRemountRefusal = disk.writes
            named(limit) { pointer, length in
                #expect(mounted.createContainer(
                    pointer, length: length, quota: 0, in: FSLayout.rootObject
                ).status == .unsupportedCapacity)
            }
            #expect(disk.writes == beforeRemountRefusal)

            named(0) { pointer, length in
                #expect(mounted.remove(pointer, length: length, from: FSLayout.rootObject) == .ok)
            }
            named(limit) { pointer, length in
                #expect(mounted.createContainer(
                    pointer, length: length, quota: 0, in: FSLayout.rootObject
                ).status == .ok)
            }
        }
    }

    @Test("a raw 1025th container is quarantined and never published")
    func rawOverLimitContainerFailsClosed() {
        let disk = MemoryDisk(sectors: Self.wideSectors)
        let space = scratch()
        defer { space.deallocate() }
        guard var fs = FileSystem.format(disk, scratch: space).disk else { Issue.record("format"); return }
        let limit = FileSystem<MemoryDisk>.maxContainersV02
        for index in 0..<(limit - 1) {
            guard container(&fs, index, room: 0) != nil else { Issue.record("container \(index)"); return }
        }
        #expect(fs.unmount() == .ok)

        let target = UInt32(limit)
        let offset = Int(fs.plan.tableStart) * Int(FSLayout.blockSize) + Int(target) * Int(FSLayout.objectSize)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Int(FSLayout.objectSize)) { raw in
            raw.initialize(repeating: 0)
            var forged = FSObject(kind: .container, created: 0, container: FSLayout.rootObject)
            forged.parent = FSLayout.rootObject
            forged.write(to: UnsafeMutableRawPointer(raw.baseAddress!))
            for index in 0..<Int(FSLayout.objectSize) { disk.poke(raw[index], at: offset + index) }
        }

        let findings = fs.scan(.everything)
        #expect(findings.tooManyContainers)
        #expect(!findings.quotasChecked)
        #expect(!findings.safeToServe)

        let guarded = scratch()
        defer { guarded.deallocate() }
        let mount = FileSystem.mount(disk, scratch: guarded)
        #expect(mount.disk == nil)
        if case .corrupt = mount.found {} else { Issue.record("mount \(mount.found)") }
    }


    @Test("a container at a high object slot is checked like any other")
    func containerAtAHighSlot() {
        // The index is keyed by *count* and not by slot, so a container past the
        // first thousand object slots is nothing special. It used to be a window
        // over slot numbers, and a second window cost a second pass.
        withFileSystem(sectors: Self.wideSectors) { fs, _ in
            #expect(fs.plan.objectCount > UInt32(FileSystem<MemoryDisk>.maxContainersV02))

            // Fill the first thousand slots with plain files, so the container
            // below lands past them.
            for index in 0..<1100 {
                var made = false
                named(index) { pointer, length in
                    made = fs.create(
                        pointer, length: length, kind: .file, in: FSLayout.rootObject
                    ).status == .ok
                }
                guard made else {
                    Issue.record("file \(index) would not be made")
                    return
                }
            }

            let name = "far" as StaticString
            let made = fs.createContainer(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                quota : 4,
                in    : FSLayout.rootObject
            )

            guard made.status == .ok else {
                Issue.record("the far container would not be made: \(made.status)")
                return
            }

            #expect(made.object >= UInt32(FileSystem<MemoryDisk>.maxContainersV02),
                    "the container landed at \(made.object), inside the first thousand")

            let findings = fs.scan(.everything)

            #expect(findings.complete)
            #expect(findings.quotasChecked)
            #expect(!findings.tooManyContainers)
            #expect(findings.wrongQuota == 0)
            #expect(!fs.corrupted)
        }
    }


    // MARK: - Room that does not add up

    /// Puts a wrong `used` on a container's record, behind the file system's
    /// back.
    private func spoilRoom(_ disk: MemoryDisk, _ plan: FSLayout.Plan, _ object: UInt32) {
        let at = Int(plan.tableStart) * Int(FSLayout.blockSize)
            + Int(object) * Int(FSLayout.objectSize)

        // `used` at byte 36. Something plausible and wrong: the container claims
        // to be holding a block it is not.
        disk.poke(UInt32(7), at: at + 36)
    }


    @Test("a wrong room is put right on a dirty mount")
    func dirtyMountRebuildsRoom() {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        var made: UInt32 = 0
        var plan: FSLayout.Plan? = nil

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }
        plan = fs.plan

        guard let object = container(&fs, 1, room: 40) else {
            Issue.record("container"); return
        }
        made = object

        // Not unmounted, so the next mount finds it dirty - which is what a power
        // cut leaves.
        guard let plan else { return }
        spoilRoom(disk, plan, made)

        remount(disk) { again, found in
            #expect(isOK(found))
            #expect(again.wasDirty)

            // Recomputed from the records charged to it, which is nothing: the
            // container is empty, so it holds nothing.
            #expect(again.object(made)?.used == 0)

            // And a repair, not a refusal: the volume is safe to serve.
            #expect(!again.corrupted)

            // Asked again, it agrees.
            let after = again.scan(.everything)
            #expect(after.wrongQuota == 0)
            #expect(after.safeToServe)
        }
    }


    @Test("a wrong room on a clean volume is damage, not something to tidy away")
    func cleanMountHoldsWrongRoom() {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        var made: UInt32 = 0
        var plan: FSLayout.Plan? = nil

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }
        plan = fs.plan

        guard let object = container(&fs, 1, room: 40) else {
            Issue.record("container"); return
        }
        made = object

        // Shut down tidily. Nothing was interrupted, so a number that does not
        // add up afterwards was not left half written: it is damage, or a bug.
        #expect(fs.unmount() == .ok)

        guard let plan else { return }
        spoilRoom(disk, plan, made)

        let attempt = FileSystem.mount(disk, scratch: scratch())
        #expect(attempt.disk == nil)
        if case .corrupt = attempt.found {} else { Issue.record("clean damage was published") }
    }


    // MARK: - Findings are about a moment

    @Test("findings from before a change are refused")
    func staleFindingsRefused() {
        withFileSystem { fs, _ in
            // Something to repair: blocks marked used that nothing owns.
            #expect(fs.begin() == .ok)
            _ = fs.allocateRun(4)
            #expect(fs.commit() == .ok)

            let findings = fs.scan()
            #expect(findings.repairable)

            // A change in between. The findings said "nothing owns these blocks",
            // which was true then; applying it now would free blocks whose owner
            // was written since.
            let name = "since.bin" as StaticString
            #expect(fs.create(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                kind  : .file,
                in    : FSLayout.rootObject
            ).status == .ok)

            #expect(fs.repair(findings) == .busy)

            // Taken again, they are about this moment and are accepted.
            let fresh = fs.scan()
            #expect(fresh.mutations != findings.mutations)
            #expect(fs.repair(fresh) == .ok)
        }
    }


    @Test("findings from another mount of the same disk are refused")
    func findingsDoNotCrossAMount() {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }

        #expect(fs.begin() == .ok)
        _ = fs.allocateRun(4)
        #expect(fs.commit() == .ok)

        let findings = fs.scan()
        #expect(findings.repairable)
        #expect(fs.unmount() == .ok)

        // Every mount bumps the superblock generation, so a set of findings
        // cannot be carried across a reboot even if nothing else changed.
        let attempt = FileSystem.mount(disk, scratch: scratch())
        #expect(attempt.disk == nil)
        if case .corrupt = attempt.found {} else { Issue.record("unsafe map was published") }
    }


    // MARK: - The journal comes first

    @Test("the journal is replayed before anything is scanned")
    func replayBeforeScan() {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }

        let name = "kept.bin" as StaticString
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        guard made.status == .ok else { Issue.record("create"); return }

        let payload = UnsafeMutableRawPointer.allocate(
            byteCount: Int(FSLayout.blockSize) * 2, alignment: 8
        )
        defer { payload.deallocate() }
        payload.initializeMemory(
            as: UInt8.self, repeating: 0x5A, count: Int(FSLayout.blockSize) * 2
        )

        // The growth is committed and then the disk stops answering part way
        // through putting the after-images on their home blocks. The journal says
        // `committed`, so the transaction exists; the object table does not have
        // it yet.
        var stopped = false
        for stop in 1...40 {
            let attempt = MemoryDisk(sectors: Self.sectors)
            _ = attempt

            disk.failAfter(stop)
            let done = fs.write(
                made.object, at: 0, from: UnsafeRawPointer(payload),
                count: FSLayout.blockSize * 2
            )
            disk.recover()

            if done.status != .ok, !fs.journalIsEmpty {
                stopped = true
                break
            }

            // Undo and try the next stopping point.
            if done.status == .ok { _ = fs.truncate(made.object, to: 0) }
        }

        guard stopped else {
            Issue.record("no stopping point left the journal holding a promise")
            return
        }

        // A new mount. It replays first, so the record the scan reads is the one
        // the transaction wrote - and the blocks it names are owned. A scan that
        // ran before the replay would call them nobody's and give them away.
        remount(disk) { again, found in
            #expect(isOK(found))
            #expect(again.journalIsEmpty)

            let findings = again.putRight()
            #expect(findings.complete)

            guard let record = again.object(made.object) else {
                Issue.record("the file is gone")
                return
            }

            // Either the growth landed or it did not, and either way its blocks
            // agree with the map.
            #expect(findings.ownedButFree == 0)
            #expect(record.blocks == 0 || record.blocks == 2)

            if record.blocks == 2 {
                #expect(findings.reclaimable == 0,
                        "the blocks of a committed growth were called nobody's")
            }
        }
    }


    // MARK: - A recovery that cannot finish

    @Test("a disk that stops answering during recovery is left dirty and unchecked")
    func failedRecoveryStaysDirty() {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }

        guard container(&fs, 1, room: 40) != nil else { Issue.record("container"); return }

        // Left dirty on purpose.
        remount(disk) { again, found in
            #expect(isOK(found))
            #expect(again.wasDirty)

            // The mounted mark, as it stands on the medium. It must not become
            // clean because a recovery failed.
            let mark = again.mountedMark
            #expect(mark != 0)

            disk.failAfter(1)
            let findings = again.putRight()
            disk.recover()

            // Nothing is vouched for, which is what a caller reads to decide not
            // to serve the volume.
            #expect(!findings.complete)
            #expect(!findings.quotasChecked)

            // And still dirty, so the next boot tries again.
            #expect(again.mountedMark != 0)
        }

        // Which the next mount duly does.
        remount(disk) { again, found in
            #expect(isOK(found))
            #expect(again.wasDirty)

            let findings = again.putRight()
            #expect(findings.complete)
        }
    }
}
