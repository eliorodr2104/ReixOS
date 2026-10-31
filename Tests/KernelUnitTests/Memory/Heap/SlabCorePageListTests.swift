//
//  SlabCorePageListTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// `SlabCore`'s per-page free lists and per-class partial-page lists, over the
/// host backend: every operation's success path, each refusal it can produce,
/// the class boundaries, every page-state transition in every order, exhaustion
/// with its rollbacks, corrupted links, and a seeded stress with the invariant
/// checker run after every step.
///
/// No global state, so this suite is parallel safe on its own.
@Suite("Slab core page lists")
struct SlabCorePageListTests {

    private typealias Core = SlabCore<HostSlabBackend>

    /// Usable blocks per page for each class, shift 3 through 12.
    private static let usable: [UInt8: Int] = [
        3: 501, 4: 252, 5: 126, 6: 63, 7: 31,
        8: 16,  9: 8,   10: 4,  11: 2, 12: 1,
    ]

    /// What the test believes is live, which the checker holds the core to.
    private struct Tracker {
        var live    : Set<UInt> = []
        var retained: Set<UInt> = []

        mutating func alloc(_ core: inout Core, _ size: UInt) -> UnsafeMutableRawPointer? {
            guard let pointer = core.alloc(size: size) else { return nil }
            #expect(live.insert(UInt(bitPattern: pointer)).inserted, "handed out a live block")
            return pointer
        }

        /// `alloc` through `#require`, so a refusal fails the test by name
        /// instead of trapping the whole run.
        mutating func take(
            _ core        : inout Core,
            _ size        : UInt,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> UnsafeMutableRawPointer {
            let pointer = alloc(&core, size)
            return try #require(pointer, sourceLocation: sourceLocation)
        }

        mutating func free(_ core: inout Core, _ pointer: UnsafeMutableRawPointer) {
            let freed = core.free(pointer)
            #expect(freed)
            live.remove(UInt(bitPattern: pointer))
        }
    }


    // MARK: - Boundaries

    @Test("every size lands in the class of its next power of two, from 1 to a page")
    func classBoundaries() throws {
        try withSlabCore(pages: 32) { core in
            var cases: [(UInt, UInt)] = [(1, 8), (7, 8), (8, 8), (9, 16)]
            for shift in 4...12 {
                cases.append((UInt(1) << UInt(shift), UInt(1) << UInt(shift)))
                cases.append(((UInt(1) << UInt(shift - 1)) + 1, UInt(1) << UInt(shift)))
            }

            for (size, capacity) in cases {
                let block = core.alloc(size: size)
                let pointer = try #require(block, "size \(size)")
                #expect(core.allocationSize(of: pointer) == capacity, "size \(size)")
                #expect(UInt(bitPattern: pointer) % capacity == 0, "size \(size)")
            }

            let zero     = core.alloc(size: 0)
            let overPage = core.alloc(size: 4097)
            let huge     = core.alloc(size: UInt.max)
            let pow2Top  = core.alloc(size: (UInt(1) << (UInt.bitWidth - 1)) + 1)
            #expect(zero == nil && overPage == nil && huge == nil && pow2Top == nil)
        }
    }


    @Test("small classes reserve whole blocks for bitmap and header, large classes none")
    func reservationPerClass() {
        let expected: [UInt8: Int] = [3: 11, 4: 4, 5: 2, 6: 1, 7: 1, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0]
        for (shift, reserved) in expected {
            #expect(Core.reservedBlockCount(forShift: shift) == reserved, "shift \(shift)")
            #expect((4096 >> Int(shift)) - reserved == Self.usable[shift], "shift \(shift)")

            // A whole page of the class, from a one-page pool: exactly the usable
            // blocks, none below the reservation.
            withSlabCore(pages: 1) { core in
                var tracker = Tracker()
                var count = 0
                var lowest = UInt.max
                while let block = tracker.alloc(&core, UInt(1) << UInt(shift)) {
                    count += 1
                    lowest = min(lowest, UInt(bitPattern: block) & 0xFFF)
                }
                #expect(count == Self.usable[shift], "shift \(shift)")
                #expect(lowest == UInt(reserved << Int(shift)), "shift \(shift)")
                expectSound(core, tracker)
            }
        }
        #expect(Core.reservedBlockCount(forShift: 2) == 0)
        #expect(Core.reservedBlockCount(forShift: 13) == 0)
    }


    // MARK: - Hand-out order

    @Test("every block of a fresh page goes out exactly once, in address order, in every class")
    func freshPageHandOutOrder() {
        for shift in UInt8(3)...12 {
            withSlabCore(pages: 1) { core in
                let size = UInt(1) << UInt(shift)
                let reserved = Core.reservedBlockCount(forShift: shift)

                for index in 0..<Self.usable[shift]! {
                    let block = core.alloc(size: size)
                    let offset = block.map { UInt(bitPattern: $0) & 0xFFF }
                    #expect(offset == UInt(reserved + index) << UInt(shift), "shift \(shift) block \(index)")
                    if block == nil { break }
                }

                let pastTheEnd = core.alloc(size: size)
                #expect(pastTheEnd == nil, "shift \(shift) served past its last block")
            }
        }
    }


    @Test("a new small page is used in place: the bump hands out blocks in order")
    func lazySmallPage() throws {
        try withSlabCore(pages: 4) { core in
            var tracker = Tracker()
            let first = try tracker.take(&core, 32)
            let page  = Core.pageBase(first)

            #expect(core.pageState(page, shift: 5).bump == 3)
            #expect(core.pageState(page, shift: 5).freeBlocks.isEmpty)

            let second = try tracker.take(&core, 32)
            let third  = try tracker.take(&core, 32)
            #expect(second == first + 32 && third == second + 32)
            #expect(core.pageState(page, shift: 5).bump == 5)

            // A freed block goes out before the bump moves, last freed first.
            tracker.free(&core, first)
            tracker.free(&core, third)
            #expect(core.pageState(page, shift: 5).freeBlocks == [4, 2])
            let reusedThird = tracker.alloc(&core, 32)
            #expect(reusedThird == third)
            let reusedFirst = tracker.alloc(&core, 32)
            #expect(reusedFirst == first)
            let bumped = tracker.alloc(&core, 32)
            #expect(bumped == third + 32)
            #expect(core.pageState(page, shift: 5).bump == 6)
            expectSound(core, tracker)
        }
    }


    @Test("a large page hands out its lowest free block and keeps its links in the highest")
    func largePageLinkSlot() throws {
        try withSlabCore(pages: 4) { core in
            var tracker = Tracker()
            let a = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            let b = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            #expect(a.map { UInt(bitPattern: $0) & 0xFFF } == [0, 1024, 2048, 3072])
            #expect(core.partialPages(shift: 10).isEmpty)

            // B partial first, then A: A is the head and B follows it.
            tracker.free(&core, b[3])
            tracker.free(&core, a[0])
            #expect(core.partialPages(shift: 10) == [Core.pageBase(a[0]), Core.pageBase(b[0])])
            expectSound(core, tracker)

            // Above the highest free block: the links move up to it.
            tracker.free(&core, a[2])
            expectSound(core, tracker)

            // Below it: they stay where they are.
            tracker.free(&core, a[1])
            expectSound(core, tracker)
            #expect(core.pageState(Core.pageBase(a[0]), shift: 10).freeBlocks == [0, 1, 2])

            // Lowest first; the third take is the link slot itself and unlinks A.
            let lowest = tracker.alloc(&core, 1024)
            #expect(lowest == a[0])
            let nextLowest = tracker.alloc(&core, 1024)
            #expect(nextLowest == a[1])
            expectSound(core, tracker)
            let linkSlot = tracker.alloc(&core, 1024)
            #expect(linkSlot == a[2])
            #expect(core.partialPages(shift: 10) == [Core.pageBase(b[0])])
            expectSound(core, tracker)
        }
    }


    // MARK: - Page-state transitions

    @Test("every class walks empty, partial, full and back, with release on the last free")
    func transitionsPerClass() throws {
        for shift in UInt8(3)...12 {
            try withSlabCore(pages: 2) { core in
                var tracker = Tracker()
                let size = UInt(1) << UInt(shift)
                let blocks = Self.usable[shift]!

                // Empty to partial (or straight to full for one block a page).
                var held = [try tracker.take(&core, size)]
                let page = Core.pageBase(held[0])
                #expect(core.partialPages(shift: shift) == (blocks > 1 ? [page] : []))
                expectSound(core, tracker)

                // Partial to full.
                while held.count < blocks { held.append(try tracker.take(&core, size)) }
                #expect(core.partialPages(shift: shift).isEmpty)
                expectSound(core, tracker)

                // Full to partial, and partial back to full off the free list.
                if blocks > 1 {
                    tracker.free(&core, held[blocks / 2])
                    #expect(core.partialPages(shift: shift) == [page])
                    expectSound(core, tracker)
                    held[blocks / 2] = try tracker.take(&core, size)
                    #expect(core.partialPages(shift: shift).isEmpty)
                }

                // Down to empty: the page goes back at the last free, not later.
                let released = core.backend.releasedPages
                for (index, pointer) in held.enumerated() {
                    tracker.free(&core, pointer)
                    #expect(core.backend.releasedPages == released + (index + 1 == blocks ? 1 : 0))
                    guard expectSound(core, tracker) else { return }
                }
                #expect(core.reservedPages == 0)
                #expect(core.partialPages(shift: shift).isEmpty)
            }
        }
    }


    @Test("freeing many pages in every order keeps the lists exact after each step")
    func transitionsInEveryOrder() throws {
        enum Order: CaseIterable { case ascending, descending, outsideIn, roundRobin, seeded }

        for shift in [UInt8(3), 6, 8, 10, 11, 12] {
            for order in Order.allCases {
                try withSlabCore(pages: 6) { core in
                    var tracker = Tracker()
                    let size = UInt(1) << UInt(shift)
                    var held: [UnsafeMutableRawPointer] = []
                    for _ in 0..<(5 * Self.usable[shift]!) { held.append(try tracker.take(&core, size)) }
                    held.sort { UInt(bitPattern: $0) < UInt(bitPattern: $1) }

                    let perPage = Self.usable[shift]!
                    var sequence: [UnsafeMutableRawPointer]
                    switch order {
                    case .ascending : sequence = held
                    case .descending: sequence = held.reversed()
                    case .outsideIn :
                        sequence = []
                        var low = 0, high = held.count - 1
                        while low <= high {
                            sequence.append(held[low])
                            if low != high { sequence.append(held[high]) }
                            low += 1; high -= 1
                        }
                    case .roundRobin:
                        sequence = []
                        for slot in 0..<perPage {
                            for page in 0..<5 { sequence.append(held[page * perPage + slot]) }
                        }
                    case .seeded:
                        var rng = SplitMix64(seed: 0x5EED_0000 + UInt64(shift))
                        sequence = held
                        for index in stride(from: sequence.count - 1, to: 0, by: -1) {
                            sequence.swapAt(index, rng.below(index + 1))
                        }
                    }

                    // Free half, refill it (partial back to full), then drain.
                    let half = sequence.count / 2
                    for (step, pointer) in sequence.prefix(half).enumerated() {
                        tracker.free(&core, pointer)
                        if step % 31 == 0 || shift >= 8, !expectSound(core, tracker) { return }
                    }
                    var refilled: [UnsafeMutableRawPointer] = []
                    for _ in 0..<half { refilled.append(try tracker.take(&core, size)) }
                    #expect(core.backend.livePages == 5, "\(order) shift \(shift)")
                    expectSound(core, tracker)
                    for (step, pointer) in (refilled + sequence.dropFirst(half)).enumerated() {
                        tracker.free(&core, pointer)
                        if step % 31 == 0 || shift >= 8, !expectSound(core, tracker) { return }
                    }
                    #expect(core.reservedPages == 0, "\(order) shift \(shift)")
                    expectSound(core, tracker)
                }
            }
        }
    }


    @Test("a page in the middle, at the head or at the tail of the list unlinks in place")
    func unlinkAnywhere() throws {
        for shift in [UInt8(6), 9] {
            try withSlabCore(pages: 4) { core in
                var tracker = Tracker()
                let size = UInt(1) << UInt(shift)
                let perPage = Self.usable[shift]!
                var pages: [[UnsafeMutableRawPointer]] = []
                for _ in 0..<3 { pages.append(try (0..<perPage).map { _ in try tracker.take(&core, size) }) }
                let base = pages.map { Core.pageBase($0[0]) }

                // One free block on each page: pushed A, then B, then C.
                for page in pages { tracker.free(&core, page[0]) }
                #expect(core.partialPages(shift: shift) == [base[2], base[1], base[0]])

                // Middle.
                for pointer in pages[1].dropFirst() { tracker.free(&core, pointer) }
                #expect(core.partialPages(shift: shift) == [base[2], base[0]])
                expectSound(core, tracker)

                // Head.
                for pointer in pages[2].dropFirst() { tracker.free(&core, pointer) }
                #expect(core.partialPages(shift: shift) == [base[0]])
                expectSound(core, tracker)

                // Tail, which is now the only page.
                for pointer in pages[0].dropFirst() { tracker.free(&core, pointer) }
                #expect(core.partialPages(shift: shift).isEmpty)
                #expect(core.reservedPages == 0)
                expectSound(core, tracker)
            }
        }
    }


    // MARK: - Refusals

    @Test("every invalid free is refused before any list or count moves")
    func refusalsLeaveStateUnchanged() throws {
        try withSlabCore(pages: 8) { core in
            var tracker = Tracker()
            let small = try (0..<4).map { _ in try tracker.take(&core, 64) }
            let large = try (0..<3).map { _ in try tracker.take(&core, 1024) }
            tracker.free(&core, small[1])
            tracker.free(&core, large[1])

            let stale = try tracker.take(&core, 2048)
            let staleTwin = try tracker.take(&core, 2048)
            tracker.free(&core, stale)
            tracker.free(&core, staleTwin)

            let foreign = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
            defer { foreign.deallocate() }

            let smallPage = Core.pageBase(small[0])
            let largePage = Core.pageBase(large[0])
            let refused: [(String, UnsafeMutableRawPointer)] = [
                ("foreign page",            foreign),
                ("null page",               UnsafeMutableRawPointer(bitPattern: 0x40)!),
                ("small interior",          small[0] + 8),
                ("small misaligned",        small[0] + 1),
                ("bitmap block",            smallPage),
                ("never handed out",        small[3] + 64),
                ("last block of the page",  smallPage + 4032),
                ("small double free",       small[1]),
                ("large interior",          large[0] + 512),
                ("large never handed out",  largePage + 3072),
                ("large double free",       large[1]),
                ("released page",           stale),
            ]

            for (name, pointer) in refused {
                let before = snapshot(core)
                let freed = core.free(pointer)
                #expect(!freed, "\(name)")
                #expect(core.freeCapacity(pointer) == nil, "\(name)")
                #expect(core.allocationSize(of: pointer) == nil, "\(name)")
                #expect(snapshot(core) == before, "\(name) changed the core")
            }

            // Nothing refused leaked into the lists: the reuse order is intact.
            let smallReuse = tracker.alloc(&core, 64)
            #expect(smallReuse == small[1])
            let largeReuse = tracker.alloc(&core, 1024)
            #expect(largeReuse == large[1])
            expectSound(core, tracker)
        }
    }


    // MARK: - Exhaustion and rollback

    @Test("exhaustion answers nil without side effects, and the pool refills after a drain")
    func exhaustionAndRecovery() {
        withSlabCore(pages: 4) { core in
            var tracker = Tracker()
            var held: [UnsafeMutableRawPointer] = []
            while let pointer = tracker.alloc(&core, 64) { held.append(pointer) }
            #expect(held.count == 4 * 63)
            guard held.count == 4 * 63 else { return }
            #expect(core.reservedPages == 4)

            let before = snapshot(core)
            for size in [UInt(8), 64, 256, 4096] {
                let refused = tracker.alloc(&core, size)
                #expect(refused == nil)
            }
            #expect(snapshot(core) == before)

            // One block back is one block of capacity, with no new page.
            tracker.free(&core, held[100])
            let refilled = tracker.alloc(&core, 64)
            #expect(refilled == held[100])
            expectSound(core, tracker)

            for pointer in held { tracker.free(&core, pointer) }
            #expect(core.reservedPages == 0)

            var again = 0
            while tracker.alloc(&core, 64) != nil { again += 1 }
            #expect(again == held.count)
            expectSound(core, tracker)
        }
    }


    @Test("a refused block transition leaves the page exactly as it was, on every path")
    func refusedTransitionRollback() throws {
        try withSlabCore(pages: 4) { core in
            var tracker = Tracker()

            // Carve: the new page goes back, nothing is listed.
            core.backend.rejectOneAllocation()
            let carveRefused = tracker.alloc(&core, 32)
            #expect(carveRefused == nil)
            #expect(core.reservedPages == 0 && core.backend.livePages == 0)

            // Bump path.
            let first = try tracker.take(&core, 32)
            var before = snapshot(core)
            core.backend.rejectOneAllocation()
            let bumpRefused = tracker.alloc(&core, 32)
            #expect(bumpRefused == nil)
            #expect(snapshot(core) == before)
            let bumpRetry = tracker.alloc(&core, 32)
            #expect(bumpRetry == first + 32)

            // Free-list path.
            tracker.free(&core, first)
            before = snapshot(core)
            core.backend.rejectOneAllocation()
            let listRefused = tracker.alloc(&core, 32)
            #expect(listRefused == nil)
            #expect(snapshot(core) == before)
            let listRetry = tracker.alloc(&core, 32)
            #expect(listRetry == first)

            // Large class, a middle block and then the last one (the link slot).
            let large = try (0..<2).map { _ in try tracker.take(&core, 2048) }
            tracker.free(&core, large[0])
            before = snapshot(core)
            core.backend.rejectOneAllocation()
            let largeRefused = tracker.alloc(&core, 2048)
            #expect(largeRefused == nil)
            #expect(snapshot(core) == before)
            let largeRetry = tracker.alloc(&core, 2048)
            #expect(largeRetry == large[0])

            let quarter = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            tracker.free(&core, quarter[0])
            tracker.free(&core, quarter[3])
            before = snapshot(core)
            core.backend.rejectOneAllocation()
            let middleRefused = tracker.alloc(&core, 1024)
            #expect(middleRefused == nil)
            #expect(snapshot(core) == before)
            expectSound(core, tracker)
        }
    }


    @Test("a page the backend will not take back stays counted, bound and off the lists")
    func retainedRelease() throws {
        try withSlabCore(pages: 4) { core in
            var tracker = Tracker()
            let blocks = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            let other  = try (0..<2).map { _ in try tracker.take(&core, 128) }

            core.backend.retainOneReleasedPage()
            for pointer in blocks { tracker.free(&core, pointer) }
            tracker.retained.insert(UInt(bitPattern: Core.pageBase(blocks[0])))

            #expect(core.reservedPages == 2)
            #expect(core.partialPages(shift: 10).isEmpty)
            expectSound(core, tracker)

            // Its blocks are no longer live, and the class carves elsewhere.
            let doubleFreed = core.free(blocks[0])
            #expect(!doubleFreed)
            let next = try tracker.take(&core, 1024)
            #expect(Core.pageBase(next) != Core.pageBase(blocks[0]))

            // Carve rollback refused by the backend: the page stays counted.
            core.backend.rejectOneAllocation()
            core.backend.retainOneReleasedPage()
            let rollbackRefused = tracker.alloc(&core, 4096)
            #expect(rollbackRefused == nil)
            #expect(core.reservedPages == 4)

            tracker.free(&core, next)
            for pointer in other { tracker.free(&core, pointer) }
            #expect(core.reservedPages == 2)
        }
    }


    // MARK: - Corrupted links

    @Test("a small-class free-list link rewritten after free is never followed out of the page")
    func corruptedSmallLink() throws {
        let reserved = UInt16(Core.reservedBlockCount(forShift: 6))

        // An out-of-range link is cut off where it is read, so nothing fails; an
        // in-range one is caught when it reaches the head, and that one call fails.
        let cases: [(String, (UInt16, UInt16) -> UInt16, Int)] = [
            ("past the page",  { _, _ in 64 },           12),
            ("all ones",       { _, _ in 0xFFFF },       12),
            ("reserved block", { _, _ in reserved - 1 }, 12),
            ("at the bump",    { _, bump in bump },      12),
            ("a live block",   { _, _ in reserved + 2 }, 11),
            ("itself",         { index, _ in index },    11),
        ]

        // A partial page, and a full one whose bump is spent, so the dropped list
        // must also take the page off its class list.
        for fill in [10, 63] {
            for (name, value, expected) in cases {
                try withSlabCore(pages: 4) { core in
                    var tracker = Tracker()
                    let held = try (0..<fill).map { _ in try tracker.take(&core, 64) }
                    for pointer in held { pointer.storeBytes(of: UInt64(0xA5A5), as: UInt64.self) }

                    tracker.free(&core, held[5])
                    tracker.free(&core, held[7])
                    let index = UInt16((UInt(bitPattern: held[7]) & 0xFFF) >> 6)
                    held[7].storeBytes(of: value(index, reserved + UInt16(fill)), as: UInt16.self)

                    // Whatever comes out is a live block of the class that was not
                    // live already, and the class keeps serving afterwards.
                    var served = 0
                    for _ in 0..<12 {
                        guard let pointer = tracker.alloc(&core, 64) else { continue }
                        served += 1
                        #expect(core.allocationSize(of: pointer) == 64, "\(name) fill \(fill)")
                    }
                    #expect(served == expected, "\(name) fill \(fill)")
                    for (index, pointer) in held.enumerated() where index != 5 && index != 7 {
                        #expect(pointer.load(as: UInt64.self) == 0xA5A5, "\(name) wrote a live block")
                    }

                    // Every live block still frees, and the page still goes back.
                    for address in tracker.live { tracker.free(&core, UnsafeMutableRawPointer(bitPattern: address)!) }
                    #expect(core.reservedPages == 0, "\(name) fill \(fill)")
                }
            }
        }
    }


    @Test("a large-class page link rewritten after free is checked before it is followed")
    func corruptedLargeLink() throws {
        // Two foreign pages with a guard on each side, all mapped: a link that
        // were followed would land in this region, not fault, and be counted.
        let region  = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 4096)
        let foreign = region + 4096
        defer { region.deallocate() }

        for target in 0..<6 {
            try withSlabCore(pages: 8) { core in
                var tracker = Tracker()
                region.initializeMemory(as: UInt8.self, repeating: 0x5A, count: 16384)

                let full  = try (0..<4).map { _ in try tracker.take(&core, 1024) }
                let a     = try (0..<4).map { _ in try tracker.take(&core, 1024) }
                let b     = try (0..<4).map { _ in try tracker.take(&core, 1024) }
                let other = try (0..<2).map { _ in try tracker.take(&core, 2048) }
                for pointer in full + a + b + other {
                    pointer.storeBytes(of: UInt64(0xC0FFEE), as: UInt64.self)
                }

                // A then B partial: B is the head, A follows, A's links in a[3].
                tracker.free(&core, a[3])
                tracker.free(&core, b[3])
                let bad: [UnsafeMutableRawPointer?] = [
                    foreign,
                    foreign + 4096 + 24,
                    Core.pageBase(full[0]),
                    Core.pageBase(other[0]),
                    Core.pageBase(a[0]),
                    foreign + 4096,
                ]
                a[3].storeBytes(of: bad[target], toByteOffset: 0, as: UnsafeMutableRawPointer?.self)
                a[3].storeBytes(of: bad[target], toByteOffset: 8, as: UnsafeMutableRawPointer?.self)

                // Emptying A unlinks it through the corrupted links, then the
                // class keeps allocating and freeing around the damage.
                for pointer in a.prefix(3) { tracker.free(&core, pointer) }
                var extra: [UnsafeMutableRawPointer] = []
                for _ in 0..<6 { if let pointer = tracker.alloc(&core, 1024) { extra.append(pointer) } }
                for pointer in extra { tracker.free(&core, pointer) }

                #expect((0..<16384).allSatisfy { region.load(fromByteOffset: $0, as: UInt8.self) == 0x5A },
                        "case \(target) wrote foreign memory")
                for pointer in full + other where tracker.live.contains(UInt(bitPattern: pointer)) {
                    #expect(pointer.load(as: UInt64.self) == 0xC0FFEE, "case \(target) wrote a live block")
                }

                for address in tracker.live { tracker.free(&core, UnsafeMutableRawPointer(bitPattern: address)!) }
                #expect(core.reservedPages == 0, "case \(target)")
            }
        }
    }


    @Test("a large page whose links name itself fills without writing outside itself")
    func selfLinkedLargePage() throws {
        try withSlabCore(pages: 8) { core in
            var tracker = Tracker()
            let before = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            let page   = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            let after  = try (0..<4).map { _ in try tracker.take(&core, 1024) }
            for pointer in before + page + after { pointer.storeBytes(of: UInt64(0xC0FFEE), as: UInt64.self) }

            // Its one free block is the link slot, and the page is the list head.
            tracker.free(&core, page[3])
            page[3].storeBytes(of: Core.pageBase(page[0]), toByteOffset: 0, as: UnsafeMutableRawPointer.self)
            page[3].storeBytes(of: Core.pageBase(page[0]), toByteOffset: 8, as: UnsafeMutableRawPointer.self)

            // Taking it fills the page; a followed self link would land in the
            // block below the page, which is a neighbour's live block.
            let last = tracker.alloc(&core, 1024)
            #expect(last == page[3])
            #expect(core.partialPages(shift: 10).isEmpty)
            for pointer in before + page.prefix(3) + after {
                #expect(pointer.load(as: UInt64.self) == 0xC0FFEE)
            }
            expectSound(core, tracker)

            // Self links on the head as it empties: the head must not be left on
            // the page that just went back.
            tracker.free(&core, page[1])
            page[1].storeBytes(of: Core.pageBase(page[0]), toByteOffset: 0, as: UnsafeMutableRawPointer.self)
            page[1].storeBytes(of: Core.pageBase(page[0]), toByteOffset: 8, as: UnsafeMutableRawPointer.self)
            for pointer in [page[0], page[2], page[3]] { tracker.free(&core, pointer) }
            #expect(core.partialPages(shift: 10).isEmpty)
            let fresh = tracker.alloc(&core, 1024)
            #expect(fresh.map { core.allocationSize(of: $0) } == 1024)
            expectSound(core, tracker)
        }
    }


    // MARK: - Stress

    @Test("seeded stress over every class holds every invariant after every step")
    func seededStress() {
        withSlabCore(pages: 24) { core in
            var tracker = Tracker()
            var payload: [UInt: UInt64] = [:]
            var held: [UnsafeMutableRawPointer] = []
            var rng = SplitMix64(seed: 0x51AB_C0DE)
            var refusals = 0

            for step in 0..<4000 {
                // Phases of growth and shrinkage, so pages fill, empty and exhaust.
                let growing = (step / 500) % 2 == 0
                if held.isEmpty || rng.below(4) < (growing ? 3 : 1) {
                    let size = UInt(1) << UInt(rng.below(10) + 3) - UInt(rng.below(2))
                    guard let pointer = tracker.alloc(&core, max(size, 1)) else {
                        refusals += 1
                        expectSound(core, tracker)
                        continue
                    }
                    let pattern = UInt64(step) &* 0x9E37_79B9 | 1
                    pointer.storeBytes(of: pattern, as: UInt64.self)
                    payload[UInt(bitPattern: pointer)] = pattern
                    held.append(pointer)
                } else {
                    let index = rng.below(held.count)
                    let pointer = held.remove(at: index)
                    #expect(pointer.load(as: UInt64.self) == payload[UInt(bitPattern: pointer)])
                    payload[UInt(bitPattern: pointer)] = nil
                    tracker.free(&core, pointer)
                }

                let problems = violations(core, tracker)
                #expect(problems.isEmpty, "step \(step): \(problems.prefix(3))")
                if !problems.isEmpty { return }
            }

            #expect(refusals > 0)
            for pointer in held { tracker.free(&core, pointer) }
            #expect(core.reservedPages == 0)
        }
    }


    // MARK: - Helpers

    private func violations(_ core: Core, _ tracker: Tracker) -> [String] {
        slabInvariantViolations(
            core,
            boundPages   : core.backend.boundPages,
            freeCount    : { Int(core.backend.freeBlocks(onPageOf: $0)) },
            live         : tracker.live,
            retainedEmpty: tracker.retained
        )
    }

    /// Records any violation and answers whether there was none, so a loop can
    /// stop at the first broken step instead of reporting every later one.
    @discardableResult
    private func expectSound(
        _ core        : Core,
        _ tracker     : Tracker,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        let problems = violations(core, tracker)
        #expect(problems.isEmpty, "\(problems)", sourceLocation: sourceLocation)
        return problems.isEmpty
    }

    /// Everything a refused operation must leave alone, as one comparable value.
    private func snapshot(_ core: Core) -> [String] {
        var lines = ["reserved \(core.reservedPages)"]
        for (page, shift) in core.backend.boundPages {
            let state = core.pageState(page, shift: shift)
            lines.append(
                "\(page) \(shift) free \(core.backend.freeBlocks(onPageOf: page)) "
                + "list \(state.freeBlocks) bump \(state.bump) "
                + "links \(String(describing: state.prev)) \(String(describing: state.next))"
            )
        }
        for shift in UInt8(3)...12 { lines.append("\(shift): \(core.partialPages(shift: shift))") }
        return lines
    }
}
