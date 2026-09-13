//
//  SlabCoreTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// `SlabCore`, which is all of `BucketsHeap` except the routing of over-a-page
/// requests to the buddy and the `FrameInfo` fields `PPMBackend` keeps the
/// per-page state in. The core is the part that decides buckets, carves pages and
/// gives them back, and it is generic over its page source, so a host backend
/// exercises the real one.
///
/// `BucketsHeap` itself cannot run here: it is built from a
/// `PhysicalPageManager` pointer and hands out `physical + 0xFFFF800000000000`,
/// an address this process does not own. See the report for the seam that would
/// be needed.
///
/// No global state, so this suite is parallel safe on its own. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("Slab core")
struct SlabCoreTests {

    private static let pageSize = 4096


    @Test("every size rounds up to a power of two and shares that bucket")
    func bucketPromotion() {
        // The bucket is `roundUpPow2(size)` floored at 8 bytes, so all three sizes
        // share one page and one free list. A wrong shift would carve a second page.
        withSlabCore(pages: 8) { core in
            let first  = core.alloc(size: 1)
            let second = core.alloc(size: 8)
            let third  = core.alloc(size: 5)

            #expect(core.backend.acquiredPages == 1)
            #expect(pageBase(first) == pageBase(second))
            #expect(pageBase(first) == pageBase(third))

            // 8 bytes apart: the carve strides by the bucket's block size.
            #expect(distance(first, second) == 8)
            #expect(distance(second, third) == 8)

            // Nine bytes is the next bucket up, so it comes off a page of its own.
            let promoted = core.alloc(size: 9)
            #expect(core.backend.acquiredPages == 2)
            #expect(pageBase(promoted) != pageBase(first))

            #expect(roundUpPow2(9)    == 16)
            #expect(roundUpPow2(4096) == 4096)
            #expect(roundUpPow2(0) == 0)
            #expect(roundUpPow2(UInt(1) << (UInt.bitWidth - 1)) == UInt(1) << (UInt.bitWidth - 1))
            #expect(roundUpPow2((UInt(1) << (UInt.bitWidth - 1)) + 1) == 0)
            #expect(roundUpPow2(UInt.max) == 0)
        }
    }


    @Test("a freed block is handed back out before a new page is taken")
    func allocFreeRoundTrip() {
        withSlabCore(pages: 8) { core in
            let first  = core.alloc(size: 32)
            let second = core.alloc(size: 32)
            #expect(core.backend.acquiredPages == 1)

            // #expect's autoclosure captures `core` as immutable, so every
            // mutating call happens in a plain statement first.
            let returned = core.free(second!)
            #expect(returned)

            // The free list is LIFO, so the block just returned is the next one out
            // and no page is acquired for it.
            let third = core.alloc(size: 32)
            #expect(third == second)
            #expect(core.backend.acquiredPages == 1)
            #expect(first != third)
        }
    }


    @Test("a page comes back to the source once its last block is freed")
    func freeCountAccounting() {
        // 2048-byte blocks: two per page, so the accounting is short enough to
        // follow block by block. This is `FrameInfo.heapFreeCount` on the machine.
        withSlabCore(pages: 8) { core in
            let first = core.alloc(size: 2048)!

            // One of the two blocks is out, so one is still free.
            #expect(core.backend.freeBlocks(onPageOf: first) == 1)

            let second = core.alloc(size: 2048)!
            #expect(pageBase(first) == pageBase(second))
            #expect(core.backend.freeBlocks(onPageOf: first) == 0)
            #expect(core.backend.acquiredPages == 1)
            #expect(core.backend.releasedPages == 0)

            let firstFreed = core.free(first)
            #expect(firstFreed)
            #expect(core.backend.releasedPages == 0)

            // Both blocks free: the page is empty and goes back, and the block list
            // must be purged of it or the next allocation hands out a released page.
            let secondFreed = core.free(second)
            #expect(secondFreed)
            #expect(core.backend.releasedPages == 1)
            #expect(core.backend.livePages     == 0)

            // The recycled page is bound again from scratch, so its free count is a
            // full page of blocks minus the one just handed out.
            let reused = core.alloc(size: 2048)!
            #expect(core.backend.acquiredPages == 2)
            #expect(core.backend.freeBlocks(onPageOf: reused) == 1)
        }
    }


    @Test("a page-sized request takes a whole page and leaves no free list")
    func wholePageBucket() {
        withSlabCore(pages: 8) { core in
            let page = core.alloc(size: UInt(Self.pageSize))!
            #expect(UInt(bitPattern: page) % UInt(Self.pageSize) == 0)
            #expect(core.backend.freeBlocks(onPageOf: page) == 0)

            // One block per page, so a second request of that size cannot be served
            // from this page and must acquire another.
            _ = core.alloc(size: UInt(Self.pageSize))
            #expect(core.backend.acquiredPages == 2)

            // The wrapper routes anything larger to the buddy allocator, so the core
            // itself refuses it rather than carving a block it cannot fit.
            let oversized = core.alloc(size: UInt(Self.pageSize) + 1)
            let empty     = core.alloc(size: 0)
            #expect(oversized == nil)
            #expect(empty     == nil)
        }
    }


    @Test("a pointer that is not on a bound page is not freed")
    func rejectsUnboundPointer() {
        withSlabCore(pages: 8) { core in
            let live = core.alloc(size: 64)!

            // A page the core never carved reports shift 0, which is what tells an
            // invalid free from a live block. `BucketsHeap` panics on the `false`.
            let stranger = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 64)
            defer { stranger.deallocate() }
            let strangerFreed = core.free(stranger)
            #expect(!strangerFreed)

            let liveFreed = core.free(live)
            #expect(liveFreed)

            // That was the page's only live block, so the page went back and is no
            // longer bound: the same pointer is now refused as the stranger was.
            #expect(core.backend.livePages == 0)

            let doubleFreed = core.free(live)
            #expect(!doubleFreed)
        }
    }


    @Test("duplicate and interior frees leave the live allocation and free list intact")
    func rejectsDuplicateAndInteriorPointers() {
        withSlabCore(pages: 8) { core in
            let first  = core.alloc(size: 64)!
            let second = core.alloc(size: 64)!

            first.storeBytes(of: UInt64(0x1122_3344_5566_7788), as: UInt64.self)

            let interiorFreed = core.free(first + 8)
            #expect(!interiorFreed)
            #expect(first.load(as: UInt64.self) == 0x1122_3344_5566_7788)

            let secondFreed = core.free(second)
            #expect(secondFreed)
            let duplicateFreed = core.free(second)
            #expect(!duplicateFreed)

            let reused = core.alloc(size: 64)
            let next   = core.alloc(size: 64)
            #expect(reused == second)
            #expect(next != second)
            #expect(first.load(as: UInt64.self) == 0x1122_3344_5566_7788)
        }
    }


    @Test("an aligned address for a free block is not accepted as a live allocation")
    func rejectsNeverAllocatedBlock() {
        withSlabCore(pages: 8) { core in
            let live = core.alloc(size: 128)!
            let neverAllocated = live + 128

            let freed = core.free(neverAllocated)
            #expect(!freed)

            let next = core.alloc(size: 128)
            #expect(next == neverAllocated)
            #expect(core.backend.acquiredPages == 1)
        }
    }


    @Test("a stale address that is not a block head in the rebound class is rejected")
    func rejectsPointerFromPreviousClass() {
        withSlabCore(pages: 1) { core in
            let oldHead = core.alloc(size: 2048)!
            let oldTail = core.alloc(size: 2048)!
            let freedHead = core.free(oldHead)
            let freedTail = core.free(oldTail)
            #expect(freedHead)
            #expect(freedTail)

            let rebound = core.alloc(size: 4096)!
            #expect(rebound == oldHead)

            // The tail used to be a block head, but is interior to the rebound
            // 4096-byte class and cannot free or alias its live allocation.
            let staleFreed = core.free(oldTail)
            #expect(!staleFreed)
            #expect(core.allocationSize(of: rebound) == 4096)
            let reboundFreed = core.free(rebound)
            #expect(reboundFreed)
        }
    }


    @Test("small bucket bitmap reservation is bounded and never handed out")
    func smallBucketMetadataCapacity() {
        withSlabCore(pages: 1) { core in
            var blocks: [UnsafeMutableRawPointer] = []
            while let block = core.alloc(size: 8) { blocks.append(block) }

            #expect(SlabCore<HostSlabBackend>.reservedBlockCount(forShift: 3) == 8)
            #expect(blocks.count == 504)
            #expect(blocks.allSatisfy { UInt(bitPattern: $0) & UInt(0xFFF) >= 64 })

            for block in blocks {
                let freed = core.free(block)
                #expect(freed)
            }
            #expect(core.backend.livePages == 0)
        }
    }


    @Test("deterministic mixed allocation stress preserves payloads, uniqueness, and accounting")
    func deterministicMixedStress() {
        struct LiveBlock {
            let pointer: UnsafeMutableRawPointer
            let bucket : UInt
            let pattern: UInt64
        }

        withSlabCore(pages: 64) { core in
            let sizes: [UInt] = [1, 8, 9, 31, 64, 127, 256, 511, 1024, 2048, 4096]
            var live: [LiveBlock] = []
            var addresses: Set<UInt> = []
            var state: UInt64 = 0xA110_CA7E_5EED_0001
            var sawOutOfMemory = false

            for step in 0..<6_000 {
                state = state &* 6364136223846793005 &+ 1442695040888963407

                if live.isEmpty || (state & 3) != 0 {
                    let size = sizes[Int((state >> 8) % UInt64(sizes.count))]
                    guard let pointer = core.alloc(size: size) else {
                        sawOutOfMemory = true
                        continue
                    }

                    let rounded = max(roundUpPow2(size), 8)
                    let address = UInt(bitPattern: pointer)
                    #expect(address % rounded == 0)
                    #expect(addresses.insert(address).inserted)

                    let pattern = UInt64(step) ^ 0xD15C_A11C_0000_0000
                    pointer.storeBytes(of: pattern, as: UInt64.self)
                    live.append(LiveBlock(pointer: pointer, bucket: rounded, pattern: pattern))
                } else {
                    let index = Int((state >> 16) % UInt64(live.count))
                    let block = live[index]
                    #expect(block.pointer.load(as: UInt64.self) == block.pattern)
                    #expect(core.allocationSize(of: block.pointer) == block.bucket)

                    let freed = core.free(block.pointer)
                    #expect(freed)
                    addresses.remove(UInt(bitPattern: block.pointer))
                    live[index] = live[live.count - 1]
                    live.removeLast()
                }
            }

            #expect(sawOutOfMemory)
            for block in live {
                #expect(block.pointer.load(as: UInt64.self) == block.pattern)
                let freed = core.free(block.pointer)
                #expect(freed)
            }
            #expect(core.backend.livePages == 0)
        }
    }


    @Test("a bucket that outgrows one page carves the next one")
    func carvesFurtherPages() {
        withSlabCore(pages: 4) { core in
            // 1024-byte blocks, four to a page.
            var blocks: [UnsafeMutableRawPointer] = []
            for _ in 0..<5 {
                guard let block = core.alloc(size: 1024) else { break }
                blocks.append(block)
            }

            #expect(blocks.count == 5)
            #expect(Set(blocks.map { UInt(bitPattern: $0) }).count == 5)
            #expect(core.backend.acquiredPages == 2)

            // The pool is four pages, so exhaustion is reported as nil rather than
            // by handing out an address the source does not own.
            for _ in 0..<16 { _ = core.alloc(size: 1024) }
            let exhausted = core.alloc(size: 1024)
            #expect(exhausted == nil)
        }
    }


    private func pageBase(_ pointer: UnsafeMutableRawPointer?) -> UInt {
        UInt(bitPattern: pointer) & ~UInt(0xFFF)
    }


    private func distance(
        _ first : UnsafeMutableRawPointer?,
        _ second: UnsafeMutableRawPointer?
    ) -> Int {
        Int(UInt(bitPattern: second)) - Int(UInt(bitPattern: first))
    }
}
