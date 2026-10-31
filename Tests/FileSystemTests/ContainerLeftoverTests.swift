//
//  ContainerLeftoverTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 01/11/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What a boot stopped in the middle of the storage check leaves in its
/// container, and what the check's isolation probe makes of it.
///
/// The probe forges sixty-three handles next to its own container's and wants
/// every one to name nothing it can reach. The server answers a forged handle
/// only when it names a live object at that generation *and* the object is inside
/// the caller's container. So an answer is either a leftover of the check's own,
/// which it may read, or a containment walk that says inside for something that
/// is not. These tests replay the check against every place a boot can stop, on
/// a disk that loses what it had not flushed, and say which of the two it is.
@Suite("What an interrupted storage check leaves behind", .serialized)
struct ContainerLeftoverTests {

    /// The QEMU disk: 16 MiB, a thousand and twenty-four object slots.
    private static let sectors: UInt64 = 32768

    private static let block = Int(FSLayout.blockSize)


    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: FileSystem<CrashDisk>.scratchBytes, alignment: 8)
    }

    private func with(_ text: String, _ body: (UnsafeRawPointer, Int) -> Void) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { body(UnsafeRawPointer($0.baseAddress!), $0.count) }
    }

    private func create(_ fs: inout FileSystem<CrashDisk>, _ name: String, in folder: UInt32) -> UInt32? {
        var made: UInt32? = nil
        with(name) { pointer, length in
            let result = fs.create(pointer, length: length, kind: .file, in: folder)
            if result.status == .ok { made = result.object }
        }
        return made
    }

    private func remove(_ fs: inout FileSystem<CrashDisk>, _ name: String, in folder: UInt32) -> FSStatus {
        var status = FSStatus.notFound
        with(name) { pointer, length in status = fs.remove(pointer, length: length, from: folder) }
        return status
    }

    private func lookup(_ fs: inout FileSystem<CrashDisk>, _ name: String, in folder: UInt32) -> UInt32? {
        var found: UInt32? = nil
        with(name) { pointer, length in found = fs.lookup(pointer, length: length, in: folder).object }
        return found
    }

    private func write(_ fs: inout FileSystem<CrashDisk>, _ object: UInt32, at offset: UInt64, _ count: Int) -> Bool {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0x5A, count: max(count, 1))
        return fs.write(object, at: offset, from: bytes, count: UInt64(count)).status == .ok
    }


    /// What init does before the check runs: its two containers, made if this is
    /// the first boot to want them, and the gift in the vault.
    private func initSetup(_ fs: inout FileSystem<CrashDisk>) -> (check: UInt32, vault: UInt32, gift: UInt32)? {
        func place(_ name: String, room: UInt32) -> UInt32? {
            if let existing = lookup(&fs, name, in: FSLayout.rootObject) { return existing }
            var made: UInt32? = nil
            with(name) { pointer, length in
                let result = fs.createContainer(pointer, length: length, quota: room, in: FSLayout.rootObject)
                if result.status == .ok { made = result.object }
            }
            return made
        }

        guard let check = place("check", room: 64), let vault = place("vault", room: 32) else { return nil }

        let gift = lookup(&fs, "gift.txt", in: vault) ?? create(&fs, "gift.txt", in: vault)
        guard let gift, write(&fs, gift, at: 0, 5000) else { return nil }

        return (check, vault, gift)
    }


    /// The check's own traffic in its container, in the order it makes it, and
    /// init's write to the orphan afterwards. Stops at the first refusal, as the
    /// process does.
    private func checkBoot(_ fs: inout FileSystem<CrashDisk>, in c: UInt32) {
        // A handle for a removed file.
        _ = remove(&fs, "one.txt", in: c)
        _ = remove(&fs, "two.txt", in: c)
        guard let one = create(&fs, "one.txt", in: c), write(&fs, one, at: 0, 3),
              remove(&fs, "one.txt", in: c) == .ok,
              let two = create(&fs, "two.txt", in: c), write(&fs, two, at: 0, 3),
              remove(&fs, "two.txt", in: c) == .ok
        else { return }

        // Two round trips.
        for _ in 0..<2 {
            _ = remove(&fs, "check.bin", in: c)
            guard let file = create(&fs, "check.bin", in: c), write(&fs, file, at: 0, 14000),
                  remove(&fs, "check.bin", in: c) == .ok
            else { return }
        }

        // A claim held and let go.
        _ = remove(&fs, "claimed.bin", in: c)
        guard let claimed = create(&fs, "claimed.bin", in: c), write(&fs, claimed, at: 0, 64),
              remove(&fs, "claimed.bin", in: c) == .ok
        else { return }

        // The dense file.
        _ = remove(&fs, "dense.bin", in: c)
        guard let dense = create(&fs, "dense.bin", in: c),
              write(&fs, dense, at: 0, 1), write(&fs, dense, at: 1, 1),
              remove(&fs, "dense.bin", in: c) == .ok
        else { return }

        // The claim the check dies holding, and init writing it afterwards.
        guard let orphan = lookup(&fs, "orphan.bin", in: c) ?? create(&fs, "orphan.bin", in: c) else { return }
        _ = write(&fs, orphan, at: 0, 1)
    }


    /// What the isolation probe gets back: the objects its sixty-three forged
    /// handles reach, decided exactly as the server decides a read.
    private func probe(_ fs: inout FileSystem<CrashDisk>, container c: UInt32) -> [UInt32] {
        let layout = FSBadge(objectCount: fs.plan.objectCount).handles
        guard let record = fs.object(c) else { return [] }
        let root = layout.encode(object: c, generation: record.generation)

        var reached: [UInt32] = []
        for twist in UInt32(1)..<UInt32(64) {
            let forged = root ^ twist
            guard let object = layout.object(of: forged),
                  let target = fs.object(object), target.kind != .free,
                  layout.names(generation: target.generation, handle: forged),
                  fs.contains(object, within: c)
            else { continue }
            reached.append(object)
        }
        return reached
    }


    /// The answers the check counts against itself: those its container does not
    /// name under the very handle that answered. The check's rule, on the host.
    private func probeFailures(_ fs: inout FileSystem<CrashDisk>, container c: UInt32) -> [UInt32] {
        let layout = FSBadge(objectCount: fs.plan.objectCount).handles

        var listed = Set<UInt32>()
        let room = UnsafeMutableRawPointer.allocate(byteCount: 256 * FSListEntry.width, alignment: 8)
        defer { room.deallocate() }

        let batch = fs.entries(from: 0, in: c, into: room, capacity: 256) { object, generation in
            layout.encode(object: object, generation: generation)
        }
        for index in 0..<batch.count {
            listed.insert(FSListEntry(reading: room.advanced(by: index * FSListEntry.width)).reference)
        }

        return probe(&fs, container: c).filter { object in
            guard let record = fs.object(object) else { return true }
            return !listed.contains(layout.encode(object: object, generation: record.generation))
        }
    }


    /// Every object named in `folder`, by walking its entries.
    private func named(_ fs: inout FileSystem<CrashDisk>, in folder: UInt32) -> Set<UInt32> {
        var names = Set<UInt32>()
        fs.forEachEntry(in: folder) { entry, _, _ in names.insert(entry.object) }
        return names
    }


    /// Whether every live record but the root is named by the folder its parent
    /// link says it is in: the condition a parent link naming a reused slot breaks.
    private func everyParentNamesItsChild(_ fs: inout FileSystem<CrashDisk>) -> Bool {
        for index in 1..<fs.plan.objectCount {
            guard case .live(let record) = fs.readObject(index) else { continue }
            guard named(&fs, in: record.parent).contains(index) else { return false }
        }
        return true
    }


    /// A disk with init's containers on it and one whole check run, left the way
    /// QEMU leaves it: killed, never unmounted.
    private func secondBoot(_ body: (CrashDisk, inout FileSystem<CrashDisk>, UInt32) -> Void) {
        let disk  = CrashDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk,
              let made = initSetup(&fs)
        else { Issue.record("fixture"); return }

        checkBoot(&fs, in: made.check)
        #expect(fs.barrier() == .ok)

        // The next boot: a dirty mount, then init again, then the check.
        let next = CrashDisk(restarting: disk)
        let other = scratch()
        defer { other.deallocate() }

        guard var again = FileSystem.mount(next, scratch: other).disk,
              let setup = initSetup(&again)
        else { Issue.record("second boot"); return }

        body(next, &again, setup.check)
    }


    @Test("a check stopped anywhere leaves answers only from its own container, all of them its own files")
    func interruptedCheckLeavesOnlyItsOwnFiles() {
        var requests = 0
        secondBoot { disk, fs, check in
            let before = disk.reads + disk.writes + disk.flushes
            checkBoot(&fs, in: check)
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 40)

        var answered = 0
        var stops    = 0
        var byName   = [String: Int]()

        for stop in 1...(requests + 1) {
            for policy in [CrashDisk.Survivors.nothing, .everything] {
                secondBoot { disk, fs, check in
                    disk.failAfter(stop)
                    checkBoot(&fs, in: check)
                    disk.powerCut(keeping: policy)

                    // The boot after: recovered, init's setup, and the probe the
                    // check runs before anything else.
                    let restarted = CrashDisk(restarting: disk)
                    let space = scratch()
                    defer { space.deallocate() }

                    guard var third = FileSystem.mount(restarted, scratch: space).disk,
                          let setup = initSetup(&third)
                    else {
                        Issue.record("stop \(stop), \(policy): would not come back")
                        return
                    }

                    stops += 1
                    let sound   = third.scan(.everything).safeToServe
                    let linked  = everyParentNamesItsChild(&third)
                    #expect(sound, "stop \(stop), \(policy)")
                    #expect(linked, "stop \(stop), \(policy): a parent link names a stranger")

                    let reached  = probe(&third, container: setup.check)
                    let ownFiles = named(&third, in: setup.check)
                    let failures = probeFailures(&third, container: setup.check)

                    #expect(failures.isEmpty, "stop \(stop), \(policy): the probe would fail on \(failures)")

                    for object in reached {
                        answered += 1

                        // Inside by name, not only by the walk: one of the check's
                        // own files, which it is allowed to read.
                        #expect(ownFiles.contains(object),
                                "stop \(stop), \(policy): object \(object) answered and is not named in the container")
                        #expect(object != setup.vault && object != setup.gift)

                        third.forEachEntry(in: setup.check) { entry, _, _ in
                            guard entry.object == object else { return }
                            let name = String(decoding: (0..<Int(entry.length)).map { entry.name[$0] }, as: UTF8.self)
                            byName[name, default: 0] += 1
                        }
                    }
                }
            }
        }

        print("  \(stops) interrupted boots, \(answered) forged handles answered, all by the check's own files: "
              + byName.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // The failure the scenario rows saw is reproduced, and is what (a) says.
        #expect(answered > 0)
    }


    @Test("an answer the container does not name still fails the probe")
    func unnamedAnswerFails() {
        // What (b) would look like: a vault file whose parent link says the check,
        // so the walk calls it inside. Nothing there names it, so it must count.
        let disk  = CrashDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk,
              let made = initSetup(&fs),
              let loot = create(&fs, "loot.bin", in: made.vault)
        else { Issue.record("fixture"); return }

        let at = Int(fs.plan.tableStart) * Self.block + Int(loot) * Int(FSLayout.objectSize) + 44
        disk.poke(made.check, at: at)
        fs.believeMedium()

        let reached  = probe(&fs, container: made.check)
        let failures = probeFailures(&fs, container: made.check)

        #expect(reached.contains(loot))
        #expect(failures == [loot])
    }


    @Test("a parent link carries no generation, so a removal frees a folder only once it names nothing")
    func parentLinkNeverDangles() {
        // The ABA a generation-less parent link would need is a folder freed while
        // a child still names it; removal refuses a folder that is not empty.
        let disk  = CrashDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk,
              let made = initSetup(&fs)
        else { Issue.record("fixture"); return }

        var folder: UInt32? = nil
        with("box") { pointer, length in
            let result = fs.create(pointer, length: length, kind: .folder, in: made.check)
            if result.status == .ok { folder = result.object }
        }
        guard let folder, let inner = create(&fs, "inner.bin", in: folder) else { Issue.record("folder"); return }

        let refused = remove(&fs, "box", in: made.check)
        let parent  = fs.object(inner)?.parent
        let inside  = fs.contains(inner, within: made.check)
        let outside = fs.contains(inner, within: made.vault)

        #expect(refused == .notEmpty)
        #expect(parent == folder)
        #expect(inside)
        #expect(!outside)
    }
}
