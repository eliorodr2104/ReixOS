//
//  BucketsHeapTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// The kernel heap as the machine builds it: `BucketsHeap` over `SlabCore` over
/// `PPMBackend` over a real `BuddyAllocator`, on a host arena.
///
/// `Tests/Support/SlabFixtures.swift` covers the same engine with a host backend of
/// its own, and says why: `PPMBackend` hands every frame out at
/// `physical + 0xFFFF800000000000`, an address this process does not own. That
/// constant is injectable on the host now (see `PPMBackend.physicalOffset`, gated
/// like `UserMemory.validationOverride`), so this suite runs the real backend and
/// reads the accounting where the machine keeps it, in `FrameInfo`.
///
/// `PPMBackend.physicalOffset` is a global. It is written and restored around each
/// body below, and `swift test --no-parallel` is what keeps another suite from
/// reading it in between: `.serialized` only orders the tests inside this one.
@Suite("Buckets heap", .serialized)
struct BucketsHeapTests {

    private struct AllocationWord: RXAllocatable {
        var value: UInt64 = 0
    }

    @Test("heap metrics separate live rounded capacity from retained backing")
    func metricAccounting() throws {
        try withHostHeap(pages: 32) { _, heap in
            #expect(heap.metricsLiveBytes == 0)
            #expect(heap.metricsReservedBytes == 0)

            let small = try allocate(&heap, 1)
            #expect(heap.metricsLiveBytes == 8)
            #expect(heap.metricsLiveHighWaterBytes == 8)
            #expect(heap.metricsReservedBytes == 4096)
            #expect(heap.metricsReservedHighWaterBytes == 4096)

            let large = try allocate(&heap, 5000)
            #expect(heap.metricsLiveBytes == 8200)
            #expect(heap.metricsLiveHighWaterBytes == 8200)
            #expect(heap.metricsReservedBytes == 12_288)
            #expect(heap.metricsReservedHighWaterBytes == 12_288)

            release(&heap, small)
            #expect(heap.metricsLiveBytes == 8192)
            #expect(heap.metricsReservedBytes == 8192)
            release(&heap, large)
            #expect(heap.metricsLiveBytes == 0)
            #expect(heap.metricsReservedBytes == 0)
            #expect(heap.metricsLiveHighWaterBytes == 8200)
            #expect(heap.metricsReservedHighWaterBytes == 12_288)
        }
    }


    @Test("an unexpected PPM reference retains slab backing in the metric")
    func retainedBackingAfterPPMRefusal() throws {
        try withHostHeap(pages: 32) { ram, heap in
            let wholePage = try allocate(&heap, 4096)
            let physical = PhysicalAddress(UInt(bitPattern: wholePage))
            let index = ram.frameIndex(of: physical)
            let allocated = ram.ppm.pointee.allocatedPages

            // Heap slab frames have one owner. An injected extra reference is
            // precisely the state PPMBackend must refuse rather than claiming
            // that PhysicalPageManager released the frame.
            ram.frames[index].refCount = 2
            release(&heap, wholePage)

            #expect(heap.metricsLiveBytes == 0)
            #expect(heap.metricsReservedBytes == 4096)
            #expect(heap.metricsReservedHighWaterBytes == 4096)
            #expect(ram.ppm.pointee.allocatedPages == allocated)
            #expect(ram.frames[index].refCount == 2)
            #expect(ram.frames[index].heapShift == 12)
        }
    }

    @Test("a request is promoted to the next power of two, floored at the smallest bucket")
    func bucketPromotion() throws {
        try withHostHeap(pages: 32) { ram, heap in
            #expect(roundUpPow2(5)   == 8)
            #expect(roundUpPow2(64)  == 64)
            #expect(roundUpPow2(100) == 128)

            // Anything under 8 bytes still gets 8: `SlabCore.minShift` is 3, so every
            // block is 8-byte aligned and a free one holds its page's free-list link.
            let tiny    = try allocate(&heap, 1)
            let five    = try allocate(&heap, 5)
            let exact   = try allocate(&heap, 64)
            let hundred = try allocate(&heap, 100)

            #expect(shift(of: tiny,    in: ram) == 3)
            #expect(shift(of: five,    in: ram) == 3)
            #expect(shift(of: exact,   in: ram) == 6)
            #expect(shift(of: hundred, in: ram) == 7)

            // One page per bucket, and the two 8-byte blocks share theirs: the shifts
            // above are three different pages' metadata and not one page's read thrice.
            #expect(page(of: five)  == page(of: tiny))
            #expect(page(of: exact) != page(of: tiny))
            #expect(page(of: hundred) != page(of: tiny))
            #expect(page(of: hundred) != page(of: exact))

            for pointer in [tiny, five, exact, hundred] {
                #expect(UInt64(UInt(bitPattern: pointer)) >= ram.base)
                #expect(UInt64(UInt(bitPattern: pointer)) <  ram.end)
            }
        }
    }


    @Test("a freed block is the next one handed out of its bucket")
    func allocFreeRoundTrip() throws {
        try withHostHeap(pages: 32) { ram, heap in
            let first  = try allocate(&heap, 32)
            let second = try allocate(&heap, 32)

            #expect(first != second)
            #expect(page(of: second) == page(of: first))

            // Written through, so this is memory the process really owns and not an
            // address the arithmetic happened to produce.
            first.storeBytes(of: UInt64(0x1122_3344_5566_7788), as: UInt64.self)
            #expect(first.load(as: UInt64.self) == 0x1122_3344_5566_7788)

            let free = frame(of: first, in: ram).heapFreeCount
            release(&heap, second)
            #expect(frame(of: first, in: ram).heapFreeCount == free + 1)

            // Straight back off the head of the bucket the free pushed it onto, and the
            // count returns with it.
            let third = try allocate(&heap, 32)
            #expect(third == second)
            #expect(frame(of: first, in: ram).heapFreeCount == free)

            // The block the write went to is untouched by its neighbour's round trip.
            #expect(first.load(as: UInt64.self) == 0x1122_3344_5566_7788)
        }
    }


    @Test("a page goes back to the allocator once every block in it is free")
    func pageReleaseAccounting() throws {
        try withHostHeap(pages: 32) { ram, heap in
            // Two blocks to a page, which is the shortest life a slab page can have.
            let first  = try allocate(&heap, 2048)
            let second = try allocate(&heap, 2048)

            #expect(page(of: second) == page(of: first))
            #expect(frame(of: first, in: ram).heapShift     == 11)
            #expect(frame(of: first, in: ram).heapFreeCount == 0)
            #expect(frame(of: first, in: ram).refCount      == 1)

            let allocated = ram.ppm.pointee.allocatedPages

            // One of the two back: the page still has a live block, so nothing is
            // handed to the allocator and the manager's count cannot move.
            release(&heap, first)
            #expect(frame(of: first, in: ram).heapFreeCount == 1)
            #expect(ram.ppm.pointee.allocatedPages == allocated)

            release(&heap, second)

            // Both counters cleared with the frame. `heapShift` back at 0 is what makes
            // a later free on this page a refusal instead of a corrupted free list.
            #expect(frame(of: first, in: ram).heapShift     == 0)
            #expect(frame(of: first, in: ram).heapFreeCount == 0)
            #expect(frame(of: first, in: ram).refCount      == 0)
            #expect(ram.ppm.pointee.allocatedPages == allocated - 1)
        }
    }


    @Test("a ProcessMetadata block lands in the 1024-byte bucket")
    func processMetadataBucket() throws {
        try withHostHeap(pages: 32) { ram, heap in
            // The one heap object allocated per process, and the reason the
            // bucket exists: 768 bytes of caps table plus its cold fields.
            //
            // It used to fit in 512 with sixteen capability slots, and at 496
            // of 512 it was one field from not fitting. Thirty-two slots put it
            // in the next bucket up, which is the price of a system where a view
            // of the disk is a capability like any other.
            let stride = MemoryLayout<ProcessMetadata>.stride
            #expect(stride > 512)
            #expect(stride <= 1024)

            let first  = UnsafeMutableRawPointer(try allocate(&heap, ProcessMetadata.self))
            let second = UnsafeMutableRawPointer(try allocate(&heap, ProcessMetadata.self))

            #expect(shift(of: first,  in: ram) == 10)
            #expect(shift(of: second, in: ram) == 10)
            #expect(page(of: second) == page(of: first))

            // Four blocks a page at this size, so two out leaves two free and the
            // second one back leaves three, with the page still the heap's.
            #expect(frame(of: first, in: ram).heapFreeCount == 2)
            release(&heap, second)
            #expect(frame(of: first, in: ram).heapFreeCount == 3)
            #expect(frame(of: first, in: ram).refCount      == 1)
        }
    }


    @Test("invalid slab addresses are rejected without changing live allocation state")
    func invalidSlabAddresses() throws {
        try withHostHeap(pages: 32) { _, heap in
            let first  = try allocate(&heap, 64)
            let second = try allocate(&heap, 64)
            first.storeBytes(of: UInt64(0xFEED_FACE_CAFE_BEEF), as: UInt64.self)

            #expect(heap.allocationSize(of: first) == 64)
            #expect(heap.allocationSize(of: first + 1) == nil)
            #expect(heap.allocationSize(of: first + 8) == nil)

            let foreign = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 64)
            defer { foreign.deallocate() }
            #expect(heap.allocationSize(of: foreign) == nil)

            release(&heap, second)
            #expect(heap.allocationSize(of: second) == nil)
            #expect(first.load(as: UInt64.self) == 0xFEED_FACE_CAFE_BEEF)

            let reused = try allocate(&heap, 64)
            #expect(reused == second)
            #expect(heap.allocationSize(of: reused) == 64)
            #expect(first.load(as: UInt64.self) == 0xFEED_FACE_CAFE_BEEF)
        }
    }


    @Test("large allocations accept only their live block head")
    func largeAllocationValidation() throws {
        try withHostHeap(pages: 32) { ram, heap in
            let before = ram.ppm.pointee.allocatedPages
            let large = try allocate(&heap, 8192)

            #expect(heap.allocationSize(of: large) == 8192)
            #expect(heap.allocationSize(of: large + 1) == nil)
            #expect(heap.allocationSize(of: large + 4096) == nil)

            release(&heap, large)
            #expect(heap.allocationSize(of: large) == nil)
            #expect(ram.ppm.pointee.allocatedPages == before)
        }
    }


    @Test("typed size overflow and invalid capacity fail before fault-injection state is consumed")
    func typedSizeArithmetic() throws {
        try withHostHeap(pages: 32) { _, heap in
            let noInitializedElements = try allocate(&heap, AllocationWord.self)
            let freedWithoutDestruction = heap.freeIfValid(noInitializedElements, count: 0)
            #expect(freedWithoutDestruction)

            let saved = BucketsHeap.failAllocationsAfter
            BucketsHeap.failAllocationsAfter = 1
            defer { BucketsHeap.failAllocationsAfter = saved }

            #expect(heap.kmallocOrNil(AllocationWord.self, -1) == nil)
            #expect(heap.kmallocOrNil(AllocationWord.self, Int.max) == nil)
            #expect(heap.kmallocOrNil(UInt.max) == nil)

            let allowed = heap.kmallocOrNil(AllocationWord.self)
            #expect(allowed != nil)
            let refused = heap.kmallocOrNil(AllocationWord.self)
            #expect(refused == nil)

            if let allowed {
                allowed.initialize(to: AllocationWord(value: 0xA110_CA7E))
                let negativeFree = heap.freeIfValid(allowed, count: -1)
                #expect(!negativeFree)
                let overflowedFree = heap.freeIfValid(allowed, count: Int.max)
                #expect(!overflowedFree)
                let oversizedFree = heap.freeIfValid(allowed, count: 2)
                #expect(!oversizedFree)
                #expect(allowed.pointee.value == 0xA110_CA7E)
                let validFree = heap.freeIfValid(allowed)
                #expect(validFree)
                let duplicateFree = heap.freeIfValid(allowed)
                #expect(!duplicateFree)
            }
        }
    }


    @Test("sizes at every boundary route to their slab class or to a buddy block")
    func routingBoundaries() throws {
        try withHostHeap(pages: 64) { ram, heap in
            #expect(heap.kmallocOrNil(0) == nil)
            #expect(heap.metricsLiveBytes == 0 && heap.metricsReservedBytes == 0)

            let cases: [(UInt, UInt, Bool)] = [
                (1, 8, false), (8, 8, false), (9, 16, false), (255, 256, false),
                (256, 256, false), (257, 512, false), (4095, 4096, false), (4096, 4096, false),
                (4097, 8192, true), (8192, 8192, true), (8193, 16384, true),
            ]
            var held: [UnsafeMutableRawPointer] = []
            var live: UInt64 = 0
            for (size, capacity, large) in cases {
                let pointer = try allocate(&heap, size)
                held.append(pointer)
                live += UInt64(capacity)
                #expect(heap.allocationSize(of: pointer) == capacity, "size \(size)")
                #expect(frame(of: pointer, in: ram).flags.contains(.heapLarge) == large, "size \(size)")
                #expect(heap.metricsLiveBytes == live, "size \(size)")
            }

            for pointer in held { release(&heap, pointer) }
            #expect(heap.metricsLiveBytes == 0 && heap.metricsReservedBytes == 0)
            #expect(heap.metricsLiveHighWaterBytes == live)
        }
    }


    @Test("every large class fills its page with distinct blocks the frame marks live")
    func largeClassLiveness() {
        withHostHeap(pages: 32) { ram, heap in
            for shift in 8...12 {
                let size = UInt(1) << UInt(shift)
                let blocks = 4096 >> shift
                var held: [UnsafeMutableRawPointer] = []

                for index in 0..<blocks {
                    let pointer = heap.kmallocOrNil(size)
                    #expect(pointer != nil, "shift \(shift) block \(index)")
                    guard let pointer else { break }
                    held.append(pointer)

                    #expect(heap.allocationSize(of: pointer) == size, "shift \(shift) block \(index)")
                    #expect(Int(frame(of: pointer, in: ram).heapFreeCount) == blocks - index - 1,
                            "shift \(shift) block \(index)")
                }
                #expect(Set(held.map { UInt(bitPattern: $0) }).count == held.count, "shift \(shift)")

                for pointer in held { release(&heap, pointer) }
                #expect(heap.metricsLiveBytes == 0 && heap.metricsReservedBytes == 0, "shift \(shift)")
            }
        }
    }


    @Test("every class gives its page back to the PPM at its last free, not later")
    func immediateReleasePerClass() throws {
        try withHostHeap(pages: 32) { ram, heap in
            let allocated = ram.ppm.pointee.allocatedPages
            for shift in 3...12 {
                let size = UInt(1) << UInt(shift)
                let blocks = (4096 >> shift) - SlabCore<PPMBackend>.reservedBlockCount(forShift: UInt8(shift))
                let held = try (0..<blocks).map { _ in try allocate(&heap, size) }
                #expect(Set(held.map { page(of: $0) }).count == 1, "shift \(shift)")
                #expect(ram.ppm.pointee.allocatedPages == allocated + 1, "shift \(shift)")

                for (index, pointer) in held.enumerated() {
                    release(&heap, pointer)
                    let expected = index + 1 == blocks ? allocated : allocated + 1
                    #expect(ram.ppm.pointee.allocatedPages == expected, "shift \(shift) free \(index)")
                }
                #expect(heap.metricsReservedBytes == 0, "shift \(shift)")
            }
        }
    }


    @Test("exhaustion fails without touching metrics, and the heap refills after a drain")
    func exhaustionAndRecovery() {
        withHostHeap(pages: 16, reservePages: 0) { ram, heap in
            let allocated = ram.ppm.pointee.allocatedPages
            var held: [UnsafeMutableRawPointer] = []
            while let pointer = heap.kmallocOrNil(64) { held.append(pointer) }
            #expect(held.count == 16 * 63)
            guard held.count == 16 * 63 else { return }

            let live     = heap.metricsLiveBytes
            let reserved = heap.metricsReservedBytes
            let highs    = (heap.metricsLiveHighWaterBytes, heap.metricsReservedHighWaterBytes)
            #expect(live == UInt64(held.count) * 64 && reserved == 16 * 4096)

            #expect(heap.kmallocOrNil(8) == nil)
            #expect(heap.kmallocOrNil(64) == nil)
            #expect(heap.kmallocOrNil(8192) == nil)
            #expect(heap.kmallocAlignedOrNil(16, alignment: 16) == nil)
            #expect(heap.metricsLiveBytes == live && heap.metricsReservedBytes == reserved)
            #expect(heap.metricsLiveHighWaterBytes == highs.0)
            #expect(heap.metricsReservedHighWaterBytes == highs.1)

            for pointer in held { release(&heap, pointer) }
            #expect(heap.metricsLiveBytes == 0 && heap.metricsReservedBytes == 0)
            #expect(ram.ppm.pointee.allocatedPages == allocated)

            var again = 0
            while again < held.count, let pointer = heap.kmallocOrNil(64) {
                held[again] = pointer
                again += 1
            }
            let beyond = heap.kmallocOrNil(64)
            #expect(again == held.count && beyond == nil)
            if let beyond { release(&heap, beyond) }
            for pointer in held.prefix(again) { release(&heap, pointer) }
            expectSound(heap, ram, live: [])
        }
    }


    @Test("aligned allocation refuses bad alignments and keeps every good one in its class")
    func alignedAllocation() throws {
        try withHostHeap(pages: 32) { ram, heap in
            #expect(heap.kmallocAlignedOrNil(8, alignment: 0) == nil)
            #expect(heap.kmallocAlignedOrNil(8, alignment: 3) == nil)
            #expect(heap.kmallocAlignedOrNil(8, alignment: 48) == nil)
            #expect(heap.metricsLiveBytes == 0)

            for (size, alignment, capacity) in [(UInt(1), UInt(1), UInt(8)), (24, 64, 64),
                                                (0, 16, 16), (1, 4096, 4096), (100, 128, 128)] {
                let aligned = heap.kmallocAlignedOrNil(size, alignment: alignment)
                let pointer = try #require(aligned)
                #expect(UInt(bitPattern: pointer) % alignment == 0, "size \(size) alignment \(alignment)")
                #expect(heap.allocationSize(of: pointer) == capacity, "size \(size) alignment \(alignment)")
                release(&heap, pointer)
            }

            // Past a page the block is a buddy block, aligned to RAM's base and not
            // necessarily to the address: either an aligned block or a clean nil.
            if let pointer = heap.kmallocAlignedOrNil(1, alignment: 8192) {
                #expect(UInt(bitPattern: pointer) % 8192 == 0)
                release(&heap, pointer)
            }
            #expect(heap.metricsLiveBytes == 0 && heap.metricsReservedBytes == 0)
            expectSound(heap, ram, live: [])
        }
    }


    @Test("seeded stress keeps lists, FrameInfo and metrics in agreement after every step")
    func seededStress() {
        withHostHeap(pages: 64, reservePages: 0) { ram, heap in
            var rng      = SplitMix64(seed: 0xB0C4_E75)
            var held     : [(pointer: UnsafeMutableRawPointer, capacity: UInt64, large: Bool)] = []
            var refusals = 0

            for step in 0..<3000 {
                let growing = (step / 400) % 2 == 0
                if held.isEmpty || rng.below(4) < (growing ? 3 : 1) {
                    let size = rng.below(16) == 0
                        ? UInt(4097 + rng.below(12000))
                        : UInt(1 + rng.below(4096))
                    guard let pointer = heap.kmallocOrNil(size) else {
                        refusals += 1
                        continue
                    }
                    let measured = heap.allocationSize(of: pointer)
                    #expect(measured != nil, "step \(step)")
                    let capacity = UInt64(measured ?? 0)
                    held.append((pointer, capacity, size > 4096))
                } else {
                    release(&heap, held.remove(at: rng.below(held.count)).pointer)
                }

                let slabLive = Set(held.filter { !$0.large }.map { UInt(bitPattern: $0.pointer) })
                let largeBytes = held.filter { $0.large }.reduce(UInt64(0)) { $0 + $1.capacity }
                #expect(heap.metricsLiveBytes == held.reduce(UInt64(0)) { $0 + $1.capacity }, "step \(step)")
                #expect(heap.metricsReservedBytes == UInt64(heap.slab.reservedPages) * 4096 + largeBytes, "step \(step)")
                #expect(heap.metricsReservedHighWaterBytes >= heap.metricsReservedBytes)
                #expect(ram.ppm.pointee.allocatedPages
                        == UInt64(heap.slab.reservedPages) + largeBytes / 4096, "step \(step)")
                let problems = violations(heap, ram, live: slabLive)
                #expect(problems.isEmpty, "step \(step): \(problems.prefix(3))")
                if !problems.isEmpty { return }
            }

            #expect(refusals > 0)
            for entry in held { release(&heap, entry.pointer) }
            #expect(heap.metricsLiveBytes == 0 && heap.metricsReservedBytes == 0)
        }
    }


    // MARK: - Fixture

    /// Runs `body` over a real `BucketsHeap` on an arena of `pages` pages.
    ///
    /// Three things are set up: a manager with the real allocator behind it (the host
    /// seam in `PhysicalPageManager.swift`), the whole arena donated to that
    /// allocator, and `PPMBackend.physicalOffset` at zero for the length of the body,
    /// because over a host arena a frame's physical address is already a pointer this
    /// process owns.
    private func withHostHeap(
        pages       : Int,
        reservePages: UInt64? = nil,
        _ body      : (HostRAM, inout BucketsHeap) throws -> Void
    ) rethrows {
        try withHostRAM(pages: pages) { ram in
            ram.installLiveManager(reservePages: reservePages)
            #expect(ram.donateAll())

            let saved = PPMBackend.physicalOffset
            PPMBackend.physicalOffset = 0
            defer { PPMBackend.physicalOffset = saved }

            var heap = BucketsHeap(ppmPtr: ram.ppm)
            try body(ram, &heap)
        }
    }


    /// The `FrameInfo` of the page `pointer` belongs to. With the offset at zero the
    /// pointer is the physical address, which is what makes this a plain lookup.
    private func frame(
        of pointer: UnsafeMutableRawPointer,
        in ram    : HostRAM
    ) -> FrameInfo {
        ram.frame(at: PhysicalAddress(UInt(bitPattern: pointer)))
    }


    /// `kmallocOrNil` through `#require`. A refusal through `kmalloc` would panic,
    /// and a host panic halts the test process instead of failing a test.
    private func allocate(
        _ heap        : inout BucketsHeap,
        _ size        : UInt,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> UnsafeMutableRawPointer {
        let pointer = heap.kmallocOrNil(size)
        return try #require(pointer, sourceLocation: sourceLocation)
    }


    private func allocate<Object: RXAllocatable>(
        _ heap        : inout BucketsHeap,
        _ type        : Object.Type,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> UnsafeMutablePointer<Object> {
        let pointer = heap.kmallocOrNil(type)
        return try #require(pointer, sourceLocation: sourceLocation)
    }


    /// `kfree` for a pointer the heap still calls live, a recorded failure for
    /// any other: `kfree` panics on it, which halts the host test process.
    private func release(
        _ heap        : inout BucketsHeap,
        _ pointer     : UnsafeMutableRawPointer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard heap.allocationSize(of: pointer) != nil else {
            Issue.record("freeing a pointer the heap does not hold live", sourceLocation: sourceLocation)
            return
        }
        heap.kfree(pointer)
    }


    /// `slabInvariantViolations` over the PPM backend: the bound pages are the
    /// frames with a heap shift and no `.heapLarge`, their free count is the one
    /// `FrameInfo` keeps.
    private func violations(
        _ heap: BucketsHeap,
        _ ram : HostRAM,
        live  : Set<UInt>
    ) -> [String] {
        var bound: [(page: UnsafeMutableRawPointer, shift: UInt8)] = []
        for index in 0..<ram.pages where ram.frames[index].heapShift != 0
                                      && !ram.frames[index].flags.contains(.heapLarge) {
            bound.append((
                UnsafeMutableRawPointer(bitPattern: UInt(ram.page(index)))!,
                ram.frames[index].heapShift
            ))
        }
        return slabInvariantViolations(
            heap.slab,
            boundPages: bound,
            freeCount : { Int(frame(of: $0, in: ram).heapFreeCount) },
            live      : live
        )
    }


    private func expectSound(
        _ heap        : BucketsHeap,
        _ ram         : HostRAM,
        live          : Set<UInt>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let problems = violations(heap, ram, live: live)
        #expect(problems.isEmpty, "\(problems)", sourceLocation: sourceLocation)
    }


    private func shift(
        of pointer: UnsafeMutableRawPointer,
        in ram    : HostRAM
    ) -> UInt8 {
        frame(of: pointer, in: ram).heapShift
    }


    private func page(of pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        SlabCore<PPMBackend>.pageBase(pointer)
    }
}
