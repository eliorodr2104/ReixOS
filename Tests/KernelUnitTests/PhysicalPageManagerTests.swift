//
//  PhysicalPageManagerTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The physical page manager's per-frame bookkeeping, over the frame metadata of a
/// host arena.
///
/// What is real here: `retain`, `release`, `refCount`, `free`, the bounds they
/// check, the block-interior sentinel and the protection flags, all reading and
/// writing the same `FrameInfo` array the machine uses.
///
/// What is staged: the manager's own allocator, which is `private` and therefore
/// zeroed. Every path below either refuses before reaching it or reaches it only
/// through `BuddyAllocator.free`, which refuses an address outside its own range
/// rather than following a pointer. `HostRAM` says why `alloc` is off limits, and
/// the report lists the seam that would open the donation paths.
///
/// No global state, so this suite is parallel safe on its own. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("Physical page manager")
struct PhysicalPageManagerTests {

    @Test("an address outside RAM reports no references instead of reading past the array")
    func boundsOnRefCount() {
        withHostRAM(pages: 8) { ram in
            // `address - ramStart` underflows below the base and indexes off the
            // end at or past `ramEnd`. Both read as 0, which callers take as unshared.
            #expect(ram.ppm.pointee.refCount(of: ram.base - 4096) == 0)
            #expect(ram.ppm.pointee.refCount(of: ram.end)         == 0)
            #expect(ram.ppm.pointee.refCount(of: ram.end + 4096)  == 0)
        }
    }


    @Test("retain adds a reference the frame reports back")
    func retainAddsReference() {
        withHostRAM(pages: 8) { ram in
            ram.setOwnedFrame(at: ram.page(3), refCount: 1)

            #expect(refusal { try ram.ppm.pointee.retain(ram.page(3)) } == "none")
            #expect(ram.ppm.pointee.refCount(of: ram.page(3)) == 2)

            // Same bound as the reader: a stray physical address out of a page table
            // must fault here rather than bump a neighbouring frame's count.
            #expect(refusal { try ram.ppm.pointee.retain(ram.end) } == "invalidRefCount")
            #expect(refusal { try ram.ppm.pointee.retain(ram.base - 4096) } == "invalidRefCount")
        }
    }


    @Test("release drops one reference and leaves a still-shared frame owned")
    func releaseDropsOneReference() {
        withHostRAM(pages: 8) { ram in
            ram.setOwnedFrame(at: ram.page(2), refCount: 2)

            #expect(refusal { try ram.ppm.pointee.release(ram.page(2)) } == "none")

            // One reference left, so the frame stays owned, the allocator is never
            // asked for it, and this is the observable the retirement tests read.
            #expect(ram.ppm.pointee.refCount(of: ram.page(2)) == 1)
            #expect(ram.frame(at: ram.page(2)).flags.contains(.reserved) == false)
        }
    }


    @Test("release refuses a frame that is inside a block rather than its head")
    func releaseRefusesBlockInterior() {
        withHostRAM(pages: 8) { ram in
            // Order 15 is the block-interior sentinel. Accepting it would rebuild a
            // differently sized block and hand that to the allocator.
            ram.setFrame(FrameInfo(refCount: 0, order: 15, flags: .none), at: ram.page(5))

            #expect(refusal { try ram.ppm.pointee.release(ram.page(5)) } == "frameNotBlockHead")

            // Refused before anything was written, so the frame is still marked as a
            // block interior for the next reader.
            #expect(ram.frame(at: ram.page(5)).order == 15)
        }
    }


    @Test("release refuses an address outside RAM")
    func releaseRefusesOutsideRam() {
        withHostRAM(pages: 8) { ram in
            #expect(refusal { try ram.ppm.pointee.release(ram.end) }         == "invalidRefCount")
            #expect(refusal { try ram.ppm.pointee.release(ram.base - 4096) } == "invalidRefCount")
        }
    }


    @Test("free refuses an unreferenced frame and a mismatched order")
    func freeGuards() {
        withHostRAM(pages: 8) { ram in
            // A frame the buddy holds free has `refCount` 0. Letting a caller drop a
            // reference nobody took is how a frame ends up on the free list twice.
            ram.setOwnedFrame(at: ram.page(1), refCount: 0)
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.page(1), order: 0))
            } == "invalidRefCount")

            // The order is checked against the metadata before the block is rebuilt,
            // so a caller cannot free a block of a size the manager never issued.
            ram.setOwnedFrame(at: ram.page(1), refCount: 1)
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.page(1), order: 3))
            } == "pageOrderMismatch")
        }
    }


    @Test("reserved and kernel frames are refused by the ordinary free")
    func protectionFlags() {
        withHostRAM(pages: 8) { ram in
            ram.setFrame(FrameInfo(refCount: 1, order: 0, flags: .reserved), at: ram.page(4))
            ram.setFrame(FrameInfo(refCount: 1, order: 0, flags: .kernel),   at: ram.page(6))

            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.page(4), order: 0))
            } == "protectedMemoryViolation")

            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.page(6), order: 0))
            } == "protectedMemoryViolation")

            // A reserved frame is refused on that path too: the boot ranges are never
            // anybody's to hand back.
            #expect(refusal {
                try ram.ppm.pointee.freeOwnedKernelPage(PhysicalPage(address: ram.page(4), order: 0))
            } == "protectedMemoryViolation")

            // A kernel frame is not: it passes the protection check and is refused by
            // the staged allocator, which is as far as a host process can follow it.
            #expect(refusal {
                try ram.ppm.pointee.freeOwnedKernelPage(PhysicalPage(address: ram.page(6), order: 0))
            } == "allocationFailed")
        }
    }


    @Test("the device tree reclaim refuses to run without frame metadata")
    func reclaimRefusesWithoutMetadata() {
        withHostRAM(pages: 8) { ram in
            ram.ppm.pointee.framesMetadata = nil

            // Logged and thrown rather than skipped: the caller reaches this through
            // `try?`, so without the throw a megabyte would go quietly missing.
            #expect(refusal { _ = try ram.ppm.pointee.reclaimDeviceTree() } == "metadataInconsistency")

            ram.ppm.pointee.framesMetadata = ram.frames
        }
    }


    @Test("a reclaim with no recorded extent frees nothing, however often it runs")
    func reclaimWithoutExtentIsIdempotent() {
        withHostRAM(pages: 8) { ram in
            // An empty extent is what a blob outside RAM leaves, and what a reclaim
            // that has already run leaves, which is what makes the call idempotent.
            let first  = try? ram.ppm.pointee.reclaimDeviceTree()
            let second = try? ram.ppm.pointee.reclaimDeviceTree()
            #expect(first  == 0)
            #expect(second == 0)

            // Nothing was handed to the allocator, so the accounting cannot have
            // moved either.
            #expect(ram.ppm.pointee.allocatedPages == 0)
        }
    }
}
