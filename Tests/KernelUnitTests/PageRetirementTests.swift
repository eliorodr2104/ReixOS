//
//  PageRetirementTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The retirement contract the initrd page-sharing design rests on: a
/// non-anonymous region is unmap only, and the frames under it are left exactly as
/// they were found.
///
/// The whole path is real. The page tables are hand-built host pages, the walker
/// that resolves and clears them is the kernel's own (with the MMU reported off,
/// `physToVirt` is the identity), and the reference counts are read out of the same
/// `FrameInfo` array `release` writes.
///
/// The frames carry two references on purpose. A `release` that reaches `free`
/// lowers the count to one and stops there, without asking the allocator for
/// anything, so the count is a direct answer to "was `release` called" and the
/// staged allocator is never touched.
///
/// `.serialized` orders this suite's own tests; it does not stop another suite from
/// running beside it, and `PageRetirement.retiredPages` is one global counter. The
/// run needs `swift test --no-parallel` (see the `test` target in the Makefile).
@Suite("Page retirement", .serialized)
struct PageRetirementTests {

    private static let pageSize: UInt64 = 4096
    private static let base    : VirtualAddress = UserSpaceLayout.elfBaseTypical


    @Test("a file-backed retirement drops the mappings and releases no frame")
    func fileBackedIsUnmapOnly() {
        withHostRAM(pages: 16) { ram in
            let mapped = map(ram, pages: 4)

            let before = PageRetirement.retiredPages
            PageRetirement.retire(
                context: context(ram),
                start  : Self.base,
                end    : Self.base + 4 * Self.pageSize,
                backing: .fileBacked
            )

            // The translations are gone: this is the half of retirement every
            // backing shares.
            for offset in 0..<4 {
                #expect(ram.translate(Self.base + UInt64(offset) * Self.pageSize) == nil)
            }

            // No frame was released: a `release` on an initrd frame would drop a
            // reference this layer never took, on a block the buddy never issued.
            for frame in mapped {
                #expect(ram.ppm.pointee.refCount(of: frame) == 2)
            }

            // The count is of mappings dropped, not of frames freed, so it moves for
            // this backing as much as for the owned one.
            #expect(PageRetirement.retiredPages &- before == 4)
        }
    }


    @Test("an anonymous retirement drops the mappings and releases every frame")
    func anonymousReleasesFrames() {
        withHostRAM(pages: 16) { ram in
            let mapped = map(ram, pages: 4)

            let before = PageRetirement.retiredPages
            PageRetirement.retire(
                context: context(ram),
                start  : Self.base,
                end    : Self.base + 4 * Self.pageSize,
                backing: .anonymous
            )

            for offset in 0..<4 {
                #expect(ram.translate(Self.base + UInt64(offset) * Self.pageSize) == nil)
            }

            // One reference each, dropped by the release the file-backed path skips:
            // the same fixture and the same range, one enum case apart.
            for frame in mapped {
                #expect(ram.ppm.pointee.refCount(of: frame) == 1)
            }

            #expect(PageRetirement.retiredPages &- before == 4)
        }
    }


    @Test("a shared retirement releases nothing either")
    func sharedIsUnmapOnly() {
        withHostRAM(pages: 16) { ram in
            let mapped = map(ram, pages: 2)

            PageRetirement.retire(
                context: context(ram),
                start  : Self.base,
                end    : Self.base + 2 * Self.pageSize,
                backing: .shared
            )

            // Owned by the `SharedRegion` that counts its own references, so the
            // same rule holds: the mapping goes, the frame stays.
            for frame in mapped {
                #expect(ram.ppm.pointee.refCount(of: frame) == 2)
            }
            #expect(ram.translate(Self.base) == nil)
        }
    }


    @Test("a range with nothing resident retires nothing")
    func absentPagesAreNotCounted() {
        withHostRAM(pages: 16) { ram in
            // No mapping at all, which is the shape of a reservation nobody touched.
            // A step bounded by frames would spin here; the count must stay put.
            let before = PageRetirement.retiredPages
            PageRetirement.retire(
                context: context(ram),
                start  : Self.base,
                end    : Self.base + 8 * Self.pageSize,
                backing: .anonymous
            )
            #expect(PageRetirement.retiredPages &- before == 0)

            let beforeFile = PageRetirement.retiredPages
            PageRetirement.retire(
                context: context(ram),
                start  : Self.base,
                end    : Self.base + 8 * Self.pageSize,
                backing: .fileBacked
            )
            #expect(PageRetirement.retiredPages &- beforeFile == 0)
        }
    }


    @Test("a half-resident file-backed range counts only what was mapped")
    func partiallyResidentRange() {
        withHostRAM(pages: 16) { ram in
            // Pages 0 and 2 of the range resident, 1 and 3 absent, so the walk has to
            // skip holes rather than stop at the first one.
            let first = ram.page(8)
            let third = ram.page(9)
            ram.setOwnedFrame(at: first, refCount: 2)
            ram.setOwnedFrame(at: third, refCount: 2)
            ram.mapPage(virtual: Self.base,                    physical: first)
            ram.mapPage(virtual: Self.base + 2 * Self.pageSize, physical: third)

            let before = PageRetirement.retiredPages
            PageRetirement.retire(
                context: context(ram),
                start  : Self.base,
                end    : Self.base + 4 * Self.pageSize,
                backing: .fileBacked
            )

            #expect(PageRetirement.retiredPages &- before == 2)
            #expect(ram.ppm.pointee.refCount(of: first) == 2)
            #expect(ram.ppm.pointee.refCount(of: third) == 2)
            #expect(ram.translate(Self.base) == nil)
            #expect(ram.translate(Self.base + 2 * Self.pageSize) == nil)
        }
    }


    /// Maps `pages` consecutive user pages at `base` onto the arena's own frames,
    /// each carrying two references, and hands back the frames used.
    private func map(
        _ ram: HostRAM,
        pages: Int
    ) -> [PhysicalAddress] {
        var frames: [PhysicalAddress] = []

        for offset in 0..<pages {
            let frame = ram.page(offset + 4)
            ram.setOwnedFrame(at: frame, refCount: 2)
            ram.mapPage(
                virtual : Self.base + UInt64(offset) * Self.pageSize,
                physical: frame
            )

            #expect(ram.translate(Self.base + UInt64(offset) * Self.pageSize) == frame)
            frames.append(frame)
        }

        return frames
    }


    private func context(_ ram: HostRAM) -> PagingContext {
        PagingContext(
            vmm              : ram.vmm,
            ppm              : ram.ppm,
            rootTablePhysical: ram.rootTablePhysical
        )
    }
}
