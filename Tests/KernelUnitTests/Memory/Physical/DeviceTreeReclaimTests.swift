//
//  DeviceTreeReclaimTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The device tree donation, over a live manager on a host arena.
///
/// What is real here: the recorded extent, the metadata clearing, the trim that
/// shortens the extent, and the `BuddyAllocator` the frames are handed to. The
/// manager comes out of the host seam at the foot of `PhysicalPageManager.swift`
/// (`installLiveManager`), which is what gives it an allocator: the boot initializer
/// needs `Kernel.platformInfo`, the linker symbols and an MMU, so no host process can
/// run it, and without the seam the allocator field stays null and every donation
/// path is closed. See `UserMemory.validationOverride` for the same gate.
///
/// The arena is this suite's own and no global is touched, so it is parallel safe on
/// its own. It runs under `swift test --no-parallel` with the rest all the same.
@Suite("Device tree reclaim")
struct DeviceTreeReclaimTests {

    @Test("the first reclaim frees exactly the recorded extent and the second frees nothing")
    func reclaimIsIdempotent() {
        withHostRAM(pages: 16) { ram in
            let start = ram.page(4)
            let end   = ram.page(8)

            ram.markReserved(from: start, to: end)
            ram.installLiveManager(deviceTree: (start: start, end: end))

            // Four withheld frames, counted as allocated exactly like the boot sweep
            // counts them: the reclaim has to give that count back and stop there.
            #expect(ram.ppm.pointee.allocatedPages == 4)

            #expect((try? ram.ppm.pointee.reclaimDeviceTree()) == 4 * 4096)
            #expect(ram.ppm.pointee.allocatedPages == 0)

            // The extent is zeroed by the first call, which is the whole of what
            // makes the second one a no-op rather than a double free.
            #expect(ram.ppm.pointee.deviceTreeExtent.start == 0)
            #expect(ram.ppm.pointee.deviceTreeExtent.end   == 0)

            #expect((try? ram.ppm.pointee.reclaimDeviceTree()) == 0)
            #expect(ram.ppm.pointee.allocatedPages == 0)
        }
    }


    @Test("the reclaimed frames come back out of the real allocator")
    func reclaimedFramesAreAllocatable() {
        withHostRAM(pages: 16) { ram in
            let start = ram.page(4)
            let end   = ram.page(8)

            // Nothing is donated to the buddy, so the extent is the only memory it can
            // ever own: whatever it hands out afterwards came from the reclaim.
            ram.markReserved(from: start, to: end)
            ram.installLiveManager(deviceTree: (start: start, end: end))

            #expect(refusal { _ = try ram.ppm.pointee.alloc(4096) } == "allocationFailed")

            #expect((try? ram.ppm.pointee.reclaimDeviceTree()) == 4 * 4096)

            var handed: [PhysicalAddress] = []
            for _ in 0..<4 {
                guard let page = try? ram.ppm.pointee.alloc(4096) else { break }
                handed.append(page.address)
            }

            #expect(handed.count == 4)
            #expect(handed.allSatisfy { $0 >= start && $0 < end })
            #expect(Set(handed).count == 4)

            // Four frames out, four frames counted, and the arena is empty again: the
            // donation was the extent and not a page more.
            #expect(ram.ppm.pointee.allocatedPages == 4)
            #expect(refusal { _ = try ram.ppm.pointee.alloc(4096) } == "allocationFailed")
        }
    }


    @Test("clearing a range leaves the all-zero record a free frame carries")
    func clearedMetadataIsAllZero() {
        withHostRAM(pages: 8) { ram in
            ram.installLiveManager()

            // Every field set to something, including the two heap ones, so a clear
            // that missed one would show up as a nonzero byte below.
            for index in 2..<5 {
                ram.setFrame(
                    FrameInfo(
                        refCount     : 3,
                        order        : 2,
                        flags        : [.reserved, .kernel],
                        heapShift    : 5,
                        heapFreeCount: 9
                    ),
                    at: ram.page(index)
                )
            }
            ram.setFrame(FrameInfo(refCount: 1, order: 0, flags: .kernel), at: ram.page(5))

            ram.ppm.pointee.clearMetadata(from: ram.page(2), to: ram.page(5))

            for index in 2..<5 {
                #expect(isAllZero(ram.frame(at: ram.page(index))))
            }

            // The top bound is exclusive, so page 5 keeps what it was carrying: a
            // clear that ran one frame long would free a frame nobody handed back.
            #expect(ram.frame(at: ram.page(5)).refCount == 1)
            #expect(ram.frame(at: ram.page(5)).flags.contains(.kernel))
        }
    }


    @Test("a reserved block reaching into the extent only ever lowers its end")
    func trimOnlyLowersTheEnd() {
        withHostRAM(pages: 16) { ram in
            for order in [false, true] {
                let start = ram.page(4)
                let end   = ram.page(12)

                ram.markReserved(from: start, to: end)
                ram.installLiveManager(deviceTree: (start: start, end: end))

                // Two blocks reaching in, visited in both orders, and the lower one
                // wins either way: the assignment cannot raise the end back up.
                var blocks = [
                    (start: ram.page(10), end: ram.page(12)),
                    (start: ram.page(11), end: ram.page(12)),
                ]
                if order { blocks.reverse() }

                ram.ppm.pointee.trimDeviceTreeExtent(againstBlocks: blocks)

                #expect(ram.ppm.pointee.deviceTreeExtent.start == start)
                #expect(ram.ppm.pointee.deviceTreeExtent.end   == ram.page(10))
            }
        }
    }


    @Test("a block starting at or below the extent collapses it to nothing")
    func trimCollapsesToEmpty() {
        withHostRAM(pages: 16) { ram in
            // Below the start, and exactly at it. Both leave an empty extent, which
            // is what the reclaim reads as nothing to do.
            for blockStart in [2, 4] {
                let start = ram.page(4)
                let end   = ram.page(8)

                ram.markReserved(from: start, to: end)
                ram.installLiveManager(deviceTree: (start: start, end: end))

                ram.ppm.pointee.trimDeviceTreeExtent(
                    againstBlocks: [(start: ram.page(blockStart), end: ram.page(6))]
                )

                let extent = ram.ppm.pointee.deviceTreeExtent
                #expect(extent.end == extent.start)

                // Nothing is handed back, and the frames stay withheld: they belong to
                // the block that reached in, whose pages are live user memory.
                #expect((try? ram.ppm.pointee.reclaimDeviceTree()) == 0)
                #expect(ram.frame(at: ram.page(4)).flags.contains(.reserved))
                #expect(ram.frame(at: ram.page(5)).flags.contains(.reserved))
            }
        }
    }


    @Test("blocks that stop at the extent's edges leave it alone")
    func trimIsANoOpWithoutOverlap() {
        withHostRAM(pages: 16) { ram in
            let start = ram.page(4)
            let end   = ram.page(8)

            ram.markReserved(from: start, to: end)
            ram.installLiveManager(deviceTree: (start: start, end: end))

            // One block ending exactly where the extent begins, one beginning exactly
            // where it ends. Both bounds are exclusive, so neither reaches in.
            ram.ppm.pointee.trimDeviceTreeExtent(againstBlocks: [
                (start: ram.page(0), end: ram.page(4)),
                (start: ram.page(8), end: ram.page(12)),
            ])

            #expect(ram.ppm.pointee.deviceTreeExtent.start == start)
            #expect(ram.ppm.pointee.deviceTreeExtent.end   == end)

            // Still the whole extent, so the untrimmed reclaim pays in full.
            #expect((try? ram.ppm.pointee.reclaimDeviceTree()) == 4 * 4096)
        }
    }


    /// Whether every byte of `info` is zero, which is the pattern `FrameInfo`
    /// documents as "free, unowned, no heap role" and the one a clear must produce.
    private func isAllZero(_ info: FrameInfo) -> Bool {
        withUnsafeBytes(of: info) { bytes in bytes.allSatisfy { $0 == 0 } }
    }
}
