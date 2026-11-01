//
//  ScaleTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// How this format behaves as the disk gets bigger, measured before anything is
/// declared about it.
///
/// The walks that grow are a scan, the recovery a dirty mount runs, and the
/// unmount that seals a volume, and every one of them is now a few passes over
/// the object table rather than one pass per bitmap block. A block-map scan is
/// one pass and one read per bitmap block. A recovery with nothing to put right
/// is that, one room pass and one names pass: `3 * tableBlocks + bitmapBlocks`
/// plus the folders. One that mends scans the whole disk again afterwards. A
/// clean mount reads the seal and the bitmap, and nothing that grows with the
/// table.
///
/// Nothing here is a guess. The geometries are measured, the numbers are printed,
/// and `FSLayout.maxSupportedBlocks` is set from them.
@Suite("How far this format goes", .serialized)
struct ScaleTests {

    /// Four geometries, and the last is the one that matters: it is past the
    /// limit this format declares, so its recovery is refused rather than
    /// measured here. `mountMatrix` measures what it would cost.
    private static let geometries: [(name: String, sectors: UInt64)] = [
        ("16 MiB", 32768),
        ("256 MiB", 524288),
        ("1 GiB", 2097152),
        ("2 GiB", 4194304),
    ]

    /// Few samples on purpose. A scan of a gibibyte is not something to do thirty
    /// times to learn what it costs, and the spread of three is enough to say
    /// whether a number is stable.
    private static let samples = 3

    private static let block = Int(FSLayout.blockSize)


    /// Enough for `sectors`, which past the declared limit is more than the
    /// fixed `scratchBytes` covers.
    private func scratch(_ sectors: UInt64 = 0) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: max(
                FileSystem<MemoryDisk>.scratchBytes,
                FileSystem<MemoryDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512)
            ),
            alignment: 8
        )
    }

    private func microseconds(_ span: Duration) -> Int {
        let parts = span.components
        return Int(parts.seconds) * 1_000_000 + Int(parts.attoseconds / 1_000_000_000_000)
    }

    /// The middle and the worst of `samples` runs, in microseconds.
    ///
    /// `worst` and not `p95`: with three samples the high end *is* the maximum,
    /// so one scheduling stall decides it. Reading it as a percentile is what
    /// made an absolute ceiling over it look like a statistic it is not.
    private func spread(_ body: () -> Void) -> (mid: Int, worst: Int) {
        var times = [Int]()

        for _ in 0..<Self.samples {
            let opened = ContinuousClock.now
            body()
            times.append(microseconds(opened.duration(to: ContinuousClock.now)))
        }

        times.sort()
        return (times[times.count / 2], times[times.count - 1])
    }


    private func named(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }


    // MARK: - The matrix

    @Test("what a scan and a recovery cost as the disk grows")
    func theMatrix() {

        print("geometry  blocks   bmap  table   scan reads  scan mid   scan worst"
              + "  recover reads  recover mid  recover worst  scrub mid")
        print(String(repeating: "-", count: 112))

        for (name, sectors) in Self.geometries {
            guard let plan = FSLayout.Plan(sectorCount: sectors, sectorSize: 512) else {
                Issue.record("\(name): no plan")
                continue
            }

            let disk  = MemoryDisk(sectors: sectors)
            let space = scratch(sectors)
            defer { space.deallocate() }

            // The private door, so a geometry past the declared limit can still
            // be measured: the limit changes what is accepted, not what it costs.
            guard var fs = FileSystem.formatUnchecked(disk, scratch: space).disk else {
                Issue.record("\(name): would not format")
                continue
            }

            // Something for the walks to find: a few files made and removed, so
            // the table is not uniformly empty and the extents are real.
            for _ in 0..<8 {
                var made: UInt32? = nil
                named("f.bin") { pointer, length in
                    let result = fs.create(
                        pointer, length: length, kind: .file, in: FSLayout.rootObject
                    )
                    if result.status == .ok { made = result.object }
                }
                guard let object = made else { break }

                let bytes = UnsafeMutableRawPointer.allocate(
                    byteCount: Self.block, alignment: 8
                )
                defer { bytes.deallocate() }
                bytes.initializeMemory(as: UInt8.self, repeating: 0x11, count: Self.block)

                _ = fs.write(object, at: 0, from: bytes, count: FSLayout.blockSize)

                named("f.bin") { pointer, length in
                    _ = fs.remove(pointer, length: length, from: FSLayout.rootObject)
                }
            }

            var scanReads = 0

            let shallow = spread {
                fs.dropCache()
                let before = disk.reads
                _ = fs.scan(.blocks)
                scanReads = disk.reads - before
            }

            let scrub = spread {
                fs.dropCache()
                _ = fs.scan(.everything)
            }

            // The boot path, and the one the service level is about: block scan,
            // room rebuild, repair, on a volume that was never unmounted.
            var recoverReads = 0

            let recover = spread {
                guard plan.totalBlocks <= FSLayout.maxSupportedBlocks else { return }
                let other = scratch(sectors)
                defer { other.deallocate() }

                guard var again = FileSystem.mountUnchecked(
                    disk, scratch: other
                ).disk else {
                    Issue.record("\(name): would not mount")
                    return
                }

                let before = disk.reads
                _ = again.putRight()
                recoverReads = disk.reads - before
            }

            // A guard against something pathological, and deliberately not a
            // performance budget.
            //
            // What the shape check below cannot catch is work that reads the
            // right number of blocks and burns the time between them - an O(n^2)
            // walk over the table in memory reads nothing extra. That is what
            // this is for, and five seconds is chosen to be far past anything a
            // slow machine does and far under anything a regression of that kind
            // would do.
            //
            // It was one second, which is two times the half second the 256 MiB
            // row takes on a quiet machine, and that is not headroom. Measured
            // on the same row: 0.52s quiet, 0.56s with the boot matrix running
            // alongside, 1.13s with all ten cores saturated as well - so the old
            // ceiling failed on a busy machine and said recovery was slow. Five
            // seconds is four times the worst of those.
            //
            // The scan and scrub timings beside it are printed and not asserted
            // at all, for the same reason: there is nothing to compare them to
            // that a loaded machine does not move.
            if plan.totalBlocks <= FSLayout.maxSupportedBlocks {
                #expect(
                    recover.worst < 5_000_000,     // microseconds, so five seconds
                    "\(name): recovery took \(recover.worst)us"
                )
            }

            // The shape, which no machine's speed changes: three table passes,
            // the sum region learnt once, the 64 for bitmap and folder reads,
            // never a fourth pass.
            if plan.totalBlocks <= FSLayout.maxSupportedBlocks {
                #expect(
                    recoverReads <= 3 * Int(plan.tableBlocks) + Int(plan.sumBlocks)
                        + Int(plan.bitmapBlocks) + 64,
                    "\(name): recovery read \(recoverReads) blocks"
                )
            } else {
                #expect(recoverReads == 0, "\(name): unsupported geometry reached service recovery")
            }

            print(pad(name, 10)
                  + pad("\(plan.totalBlocks)", 9)
                  + pad("\(plan.bitmapBlocks)", 6)
                  + pad("\(plan.tableBlocks)", 7)
                  + pad("\(scanReads)", 12)
                  + pad("\(shallow.mid)us", 10)
                  + pad("\(shallow.worst)us", 12)
                  + pad("\(recoverReads)", 15)
                  + pad("\(recover.mid)us", 13)
                  + pad("\(recover.worst)us", 15)
                  + "\(scrub.mid)us")
        }
    }


    /// What a whole mount costs, clean and dirty, and what the unmount before a
    /// clean one costs. The service level is about these and not about a scan.
    ///
    /// `model` is the host time plus fifty microseconds per device read, which
    /// is the latency the service level is stated against.
    @Test("what a clean and a dirty mount cost as the disk grows")
    func mountMatrix() {

        print("geometry  scratch  clean reads  clean mid  unmount reads  unmount mid"
              + "  dirty reads  dirty mid  dirty model  mend reads  mend mid  mend model")
        print(String(repeating: "-", count: 141))

        for (name, sectors) in Self.mountGeometries {
            guard let plan = FSLayout.Plan(sectorCount: sectors, sectorSize: 512) else {
                Issue.record("\(name): no plan")
                continue
            }

            let disk  = MemoryDisk(sectors: sectors)
            let bytes = FileSystem<MemoryDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512)
            let space = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            defer { space.deallocate() }

            guard var fs = FileSystem.formatUnchecked(disk, scratch: space).disk else {
                Issue.record("\(name): would not format")
                continue
            }
            let box = populate(&fs)

            var unmountReads = 0
            var cleanReads   = 0
            var dirtyReads   = 0

            // Clean: unmounted, then mounted, `samples` times over.
            var unmounts = [Int]()
            var cleans   = [Int]()

            for _ in 0..<Self.samples {
                var before = disk.reads
                var opened = ContinuousClock.now
                #expect(fs.unmount() == .ok, "\(name): unmount refused")
                unmounts.append(microseconds(opened.duration(to: ContinuousClock.now)))
                unmountReads = disk.reads - before

                before = disk.reads
                opened = ContinuousClock.now
                guard let again = FileSystem.mountUnchecked(disk, scratch: space).disk else {
                    Issue.record("\(name): clean mount refused")
                    return
                }
                cleans.append(microseconds(opened.duration(to: ContinuousClock.now)))
                cleanReads = disk.reads - before
                #expect(!again.wasDirty)
                fs = again
            }

            // Dirty: never unmounted, so every mount after this runs recovery.
            var dirties = [Int]()

            for _ in 0..<Self.samples {
                let before = disk.reads
                let opened = ContinuousClock.now
                guard let again = FileSystem.mountUnchecked(disk, scratch: space).disk else {
                    Issue.record("\(name): dirty mount refused")
                    return
                }
                dirties.append(microseconds(opened.duration(to: ContinuousClock.now)))
                dirtyReads = disk.reads - before
                #expect(again.wasDirty)
            }

            // Dirty with something to put right: blocks nobody owns and a room
            // that is behind, both mended, then the whole disk scanned again.
            var mends     = [Int]()
            var mendReads = 0

            for _ in 0..<Self.samples {
                #expect(fs.begin() == .ok)
                _ = fs.allocateRun(8)
                #expect(fs.commit() == .ok)

                let at = Int(plan.tableStart) * Self.block + Int(box) * Int(FSLayout.objectSize)
                disk.poke(UInt32(disk.byte(at: at + 36)) + 1, at: at + 36)

                let before = disk.reads
                let opened = ContinuousClock.now
                guard let again = FileSystem.mountUnchecked(disk, scratch: space).disk else {
                    Issue.record("\(name): a mending mount refused")
                    return
                }
                mends.append(microseconds(opened.duration(to: ContinuousClock.now)))
                mendReads = disk.reads - before
                fs = again
            }

            let dirtyMid = middle(dirties)
            let model    = dirtyMid + dirtyReads * 50
            let mendMid  = middle(mends)
            let mended   = mendMid + mendReads * 50

            print(pad(name, 10)
                  + pad("\(bytes / 1024)K", 9)
                  + pad("\(cleanReads)", 13)
                  + pad("\(middle(cleans))us", 11)
                  + pad("\(unmountReads)", 15)
                  + pad("\(middle(unmounts))us", 13)
                  + pad("\(dirtyReads)", 13)
                  + pad("\(dirtyMid)us", 11)
                  + pad("\(model)us", 13)
                  + pad("\(mendReads)", 12)
                  + pad("\(mendMid)us", 10)
                  + "\(mended)us")

            if plan.totalBlocks <= FSLayout.maxSupportedBlocks {
                #expect(model  < 1_000_000, "\(name): a dirty mount models at \(model)us")
                #expect(mended < 1_000_000, "\(name): a mending mount models at \(mended)us")
            }
        }
    }

    /// The geometries the mount matrix walks. The largest is past the declared
    /// limit, and is there to show the limit is where the model says it is.
    private static let mountGeometries: [(name: String, sectors: UInt64)] = [
        ("16 MiB", 32768),
        ("256 MiB", 524288),
        ("1 GiB", 2097152),
        ("2 GiB", 4194304),
    ]

    private func middle(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Files, folders and containers, so every walk a mount makes has something
    /// to find: names in more than one folder, and room in more than one place.
    @discardableResult
    private func populate(_ fs: inout FileSystem<MemoryDisk>) -> UInt32 {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Self.block * 4, alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block * 4)

        var places = [FSLayout.rootObject]

        for which in 0..<4 {
            withName("box", which) { pointer, length in
                let result = fs.createContainer(
                    pointer, length: length, quota: 256, in: FSLayout.rootObject
                )
                if result.status == .ok { places.append(result.object) }
            }

            withName("dir", which) { pointer, length in
                let result = fs.create(pointer, length: length, kind: .folder, in: FSLayout.rootObject)
                if result.status == .ok { places.append(result.object) }
            }
        }
        #expect(places.count == 9)

        for (at, place) in places.enumerated() {
            for which in 0..<6 {
                withName("f\(at)-", which) { pointer, length in
                    let result = fs.create(pointer, length: length, kind: .file, in: place)
                    guard result.status == .ok else {
                        Issue.record("a fixture file was refused: \(result.status)")
                        return
                    }
                    let wrote = fs.write(result.object, at: 0, from: bytes, count: UInt64(Self.block * 4))
                    #expect(wrote.status == .ok)
                }
            }
        }

        return places[1]
    }

    private func withName(_ stem: String, _ which: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        let text = Array("\(stem)\(which)".utf8)
        text.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!), buffer.count)
        }
    }


    /// The production create gate at the room-index ceiling.
    ///
    /// The accumulator was a *window* over object slots, a thousand and twenty-four
    /// wide, and a pass over the whole object table per window. So the thousand
    /// and twenty-fifth container bought a second full pass, and on a large disk a
    /// pass is the whole table. It is a bounded *index* now: two passes whatever
    /// the number of containers, and past the bound the room is reported unchecked
    /// rather than checked in pieces.
    @Test("the container ceiling refuses one more create without another room walk")
    func containersPastOneWindow() {

        // 64 MiB has enough object slots for the container ceiling while
        // keeping this production gate regression quick.
        let sectors: UInt64 = 131072

        let disk  = MemoryDisk(sectors: sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.formatUnchecked(disk, scratch: space).disk else {
            Issue.record("would not format")
            return
        }

        // Ten containers, then a thousand and thirty: either side of the window.
        var made = 0

        func fill(to wanted: Int) {
            while made < wanted {
                var ok = false
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 12) { room in
                    var length = 0
                    var value  = made
                    room[length] = UInt8(ascii: "c"); length += 1

                    repeat {
                        room[length] = UInt8(ascii: "0") + UInt8(value % 10)
                        value /= 10
                        length += 1
                    } while value > 0

                    ok = fs.createContainer(
                        UnsafeRawPointer(room.baseAddress!),
                        length: length, quota: 0, in: FSLayout.rootObject
                    ).status == .ok
                }

                guard ok else { break }
                made += 1
            }
        }

        fill(to: 10)
        guard made == 10 else {
            Issue.record("only \(made) containers were made")
            return
        }

        let few = countedRoomWalk(disk)
        #expect(few.checked)
        #expect(!few.tooMany)

        // The root is the first container. Fill the remaining production capacity
        // and prove a following request is refused before it writes.
        fill(to: FSLayout.maxContainers - 1)
        guard made == FSLayout.maxContainers - 1 else {
            Issue.record("only \(made) containers were made")
            return
        }

        let writes = disk.writes
        named("one-more") { pointer, length in
            #expect(fs.createContainer(pointer, length: length, quota: 0, in: FSLayout.rootObject).status == .unsupportedCapacity)
        }
        #expect(disk.writes == writes)
        #expect(fs.unmount() == .ok)
        for attempt in 0..<20 {
            let remountSpace = scratch()
            defer { remountSpace.deallocate() }
            let remounted = FileSystem.mount(disk, scratch: remountSpace)
            guard var atLimit = remounted.disk else {
                Issue.record("the exact-limit disk would not remount on attempt \(attempt): \(remounted.found)")
                return
            }
            let remountWrites = disk.writes
            named("one-more") { pointer, length in
                #expect(atLimit.createContainer(pointer, length: length, quota: 0, in: FSLayout.rootObject).status == .unsupportedCapacity)
            }
            #expect(disk.writes == remountWrites)
            #expect(atLimit.unmount() == .ok)
        }

        print("  room walk, 10 containers: \(few.reads) reads, \(few.time)us")
        print("  production gate, \(made + 1) containers: remounted and refused zero-write")

    }

    /// The boot path, on a dirty volume: the block scan and the room rebuild, and
    /// nothing else.
    ///
    /// Not `scan(.everything)`. That also walks every name in every folder, and
    /// the bounded name scrub uses a fixed scratch partition rather than a
    /// per-name rescan, which is intentionally separate from this room metric.
    private func countedRoomWalk(
        _ disk: MemoryDisk
    ) -> (reads: Int, time: Int, checked: Bool, tooMany: Bool) {

        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { space.deallocate() }

        // Mounted and never unmounted, so the mark says the machine before this
        // one went away: `putRight` then runs the room rebuild as well.
        guard var fs = FileSystem.mount(disk, scratch: space).disk else {
            Issue.record("the disk would not mount")
            return (0, 0, false, false)
        }
        #expect(fs.wasDirty)

        let before = disk.reads
        let opened = ContinuousClock.now

        let findings = fs.putRight()

        let time = microseconds(opened.duration(to: ContinuousClock.now))

        return (
            disk.reads - before, time,
            findings.quotasChecked, findings.tooManyContainers
        )
    }


    // MARK: - What the format will accept

    @Test("a geometry past the declared limit is refused, by both doors")
    func pastTheLimitIsRefused() {

        // One block past, so it is the limit being enforced and not the size of
        // the machine.
        let over = (UInt64(FSLayout.maxSupportedBlocks) + 1)
            * (FSLayout.blockSize / 512)

        let disk = MemoryDisk(sectors: over)

        let space = scratch(over)
        defer { space.deallocate() }

        let made = FileSystem.format(disk, scratch: space)
        #expect(made.disk == nil)
        #expect(made.made == .tooManyBlocks)

        // And nothing was written on the way to refusing.
        #expect(disk.writes == 0)

        // A disk formatted by something that did not have the limit is refused at
        // the door rather than served.
        guard FileSystem.formatUnchecked(disk, scratch: space).disk != nil else {
            Issue.record("the unchecked door would not format either")
            return
        }

        let attempt = FileSystem.mount(disk, scratch: space)
        #expect(attempt.disk == nil)

        if case .tooLarge = attempt.found {} else {
            Issue.record("mount answered \(attempt.found)")
        }
    }


    @Test("the largest geometry the format declares is accepted")
    func theLimitItselfIsAccepted() {

        let sectors = UInt64(FSLayout.maxSupportedBlocks) * (FSLayout.blockSize / 512)

        let disk  = MemoryDisk(sectors: sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the declared limit would not format")
            return
        }

        #expect(fs.plan.totalBlocks == FSLayout.maxSupportedBlocks)

        var made: UInt32? = nil
        named("edge.bin") { pointer, length in
            let result = fs.create(
                pointer, length: length, kind: .file, in: FSLayout.rootObject
            )
            if result.status == .ok { made = result.object }
        }
        #expect(made != nil)

        #expect(fs.unmount() == .ok)

        let other = scratch()
        defer { other.deallocate() }

        guard FileSystem.mount(disk, scratch: other).disk != nil else {
            Issue.record("the declared limit would not mount")
            return
        }
    }


    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
