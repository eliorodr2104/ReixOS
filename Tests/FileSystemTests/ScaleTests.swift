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
/// The two walks that grow are a scan and the recovery a dirty mount runs, and
/// they grow differently. A block-map scan reads the whole object table once
/// per bitmap block. `putRight` deliberately verifies the repaired medium with
/// a deep scan, so a dirty recovery has two such scans, plus the two room passes
/// while mending and the two room passes while verifying. The resulting measured
/// bound is `(2 * bitmapBlocks + 5) * tableBlocks`, plus bounded metadata I/O.
/// The old room walk was worse - it read the whole table once per window of a
/// thousand containers - which is the step a disk with more than one window's
/// worth used to fall off.
///
/// Nothing here is a guess. The geometries are measured, the numbers are printed,
/// and `FSLayout.maxSupportedBlocksV02` is set from them.
@Suite("How far this format goes", .serialized)
struct ScaleTests {

    /// Three geometries, and the third is the one that matters: it is past the
    /// limit this format declares, so it is refused rather than measured.
    private static let geometries: [(name: String, sectors: UInt64)] = [
        ("16 MiB", 32768),
        ("256 MiB", 524288),
        ("1 GiB", 2097152),
    ]

    /// Few samples on purpose. A scan of a gibibyte is not something to do thirty
    /// times to learn what it costs, and the spread of three is enough to say
    /// whether a number is stable.
    private static let samples = 3

    private static let block = Int(FSLayout.blockSize)


    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
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
            let space = scratch()
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
                guard plan.totalBlocks <= FSLayout.maxSupportedBlocksV02 else { return }
                let other = scratch()
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
            if plan.totalBlocks <= FSLayout.maxSupportedBlocksV02 {
                #expect(
                    recover.worst < 5_000_000,     // microseconds, so five seconds
                    "\(name): recovery took \(recover.worst)us"
                )
            }

            // And the shape, which no machine's speed changes. `putRight` first
            // scans the map, mends room in two table passes, then verifies with a
            // deep scan: a second map scan, one name pass, and two room passes.
            // That is `(2 * bitmapBlocks + 5) * tableBlocks`; the 64 leaves room
            // for bitmap and directory metadata I/O, not an unmeasured full pass.
            if plan.totalBlocks <= FSLayout.maxSupportedBlocksV02 {
                #expect(
                    recoverReads <= (2 * Int(plan.bitmapBlocks) + 5) * Int(plan.tableBlocks) + 64,
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

        // 64 MiB has enough object slots for the v02 container ceiling while
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
        fill(to: FileSystem<MemoryDisk>.maxContainersV02 - 1)
        guard made == FileSystem<MemoryDisk>.maxContainersV02 - 1 else {
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
        let over = (UInt64(FSLayout.maxSupportedBlocksV02) + 1)
            * (FSLayout.blockSize / 512)

        let disk = MemoryDisk(sectors: over)

        let space = scratch()
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

        let sectors = UInt64(FSLayout.maxSupportedBlocksV02) * (FSLayout.blockSize / 512)

        let disk  = MemoryDisk(sectors: sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the declared limit would not format")
            return
        }

        #expect(fs.plan.totalBlocks == FSLayout.maxSupportedBlocksV02)

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
