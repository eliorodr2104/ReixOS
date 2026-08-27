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

    @Test("a request is promoted to the next power of two, floored at the smallest bucket")
    func bucketPromotion() {
        withHostHeap(pages: 32) { ram, heap in
            #expect(roundUpPow2(5)   == 8)
            #expect(roundUpPow2(64)  == 64)
            #expect(roundUpPow2(100) == 128)

            // Anything under 8 bytes still gets 8: `SlabCore.minShift` is 3 because a
            // free block holds the next pointer of its list inside itself.
            let tiny    = heap.kmalloc(1)
            let five    = heap.kmalloc(5)
            let exact   = heap.kmalloc(64)
            let hundred = heap.kmalloc(100)

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
    func allocFreeRoundTrip() {
        withHostHeap(pages: 32) { ram, heap in
            let first  = heap.kmalloc(32)
            let second = heap.kmalloc(32)

            #expect(first != second)
            #expect(page(of: second) == page(of: first))

            // Written through, so this is memory the process really owns and not an
            // address the arithmetic happened to produce.
            first.storeBytes(of: UInt64(0x1122_3344_5566_7788), as: UInt64.self)
            #expect(first.load(as: UInt64.self) == 0x1122_3344_5566_7788)

            let free = frame(of: first, in: ram).heapFreeCount
            heap.kfree(second)
            #expect(frame(of: first, in: ram).heapFreeCount == free + 1)

            // Straight back off the head of the bucket the free pushed it onto, and the
            // count returns with it.
            let third = heap.kmalloc(32)
            #expect(third == second)
            #expect(frame(of: first, in: ram).heapFreeCount == free)

            // The block the write went to is untouched by its neighbour's round trip.
            #expect(first.load(as: UInt64.self) == 0x1122_3344_5566_7788)
        }
    }


    @Test("a page goes back to the allocator once every block in it is free")
    func pageReleaseAccounting() {
        withHostHeap(pages: 32) { ram, heap in
            // Two blocks to a page, which is the shortest life a slab page can have.
            let first  = heap.kmalloc(2048)
            let second = heap.kmalloc(2048)

            #expect(page(of: second) == page(of: first))
            #expect(frame(of: first, in: ram).heapShift     == 11)
            #expect(frame(of: first, in: ram).heapFreeCount == 0)
            #expect(frame(of: first, in: ram).refCount      == 1)

            let allocated = ram.ppm.pointee.allocatedPages

            // One of the two back: the page still has a live block, so nothing is
            // handed to the allocator and the manager's count cannot move.
            heap.kfree(first)
            #expect(frame(of: first, in: ram).heapFreeCount == 1)
            #expect(ram.ppm.pointee.allocatedPages == allocated)

            heap.kfree(second)

            // Both counters cleared with the frame. `heapShift` back at 0 is what makes
            // a later free on this page a refusal instead of a corrupted free list.
            #expect(frame(of: first, in: ram).heapShift     == 0)
            #expect(frame(of: first, in: ram).heapFreeCount == 0)
            #expect(frame(of: first, in: ram).refCount      == 0)
            #expect(ram.ppm.pointee.allocatedPages == allocated - 1)
        }
    }


    @Test("a ProcessMetadata block lands in the 1024-byte bucket")
    func processMetadataBucket() {
        withHostHeap(pages: 32) { ram, heap in
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

            let first  = UnsafeMutableRawPointer(heap.kmalloc(ProcessMetadata.self))
            let second = UnsafeMutableRawPointer(heap.kmalloc(ProcessMetadata.self))

            #expect(shift(of: first,  in: ram) == 10)
            #expect(shift(of: second, in: ram) == 10)
            #expect(page(of: second) == page(of: first))

            // Four blocks a page at this size, so two out leaves two free and the
            // second one back leaves three, with the page still the heap's.
            #expect(frame(of: first, in: ram).heapFreeCount == 2)
            heap.kfree(second)
            #expect(frame(of: first, in: ram).heapFreeCount == 3)
            #expect(frame(of: first, in: ram).refCount      == 1)
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
        pages : Int,
        _ body: (HostRAM, inout BucketsHeap) -> Void
    ) {
        withHostRAM(pages: pages) { ram in
            ram.installLiveManager()
            #expect(ram.donateAll())

            let saved = PPMBackend.physicalOffset
            PPMBackend.physicalOffset = 0
            defer { PPMBackend.physicalOffset = saved }

            var heap = BucketsHeap(ppmPtr: ram.ppm)
            body(ram, &heap)
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
