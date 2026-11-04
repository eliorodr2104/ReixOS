//
//  BuddyAllocatorTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The buddy allocator over a host arena, which is the real thing: its bitmap,
/// its free lists and the `FreeBlock` nodes it overlays on the free pages all sit
/// in memory this process owns, so nothing about it is stubbed.
///
/// No global state, so this suite is parallel safe on its own. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("Buddy allocator")
struct BuddyAllocatorTests {

    private static let pageSize: UInt64 = 4096

    /// Largest block the allocator will name, `pageSize << maxOrder` with
    /// `maxOrder` 11. Its own constant is private, so the bound is restated here
    /// and the asserts below are what would notice the two parting.
    private static let largestBlock: Int = 4096 << 11


    @Test("one donated block splits down to a page and merges all the way back")
    func splitMergeRoundTrip() {
        // 512 pages, so the donation is a single aligned order-9 block and the
        // split has nine levels to walk down and back up.
        withHostRAM(pages: 512) { ram in
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.base, to: ram.end) } == "none")

            let page = allocated(ram.buddy, bytes: Int(Self.pageSize))
            #expect(page?.address == ram.base)
            #expect(page?.order   == 0)

            // Every buddy from order 0 to order 8 is on a free list now, so the
            // largest block the arena can hold must be unavailable until the merge.
            #expect(refusal { _ = try ram.buddy.alloc(512 * Int(Self.pageSize)) } == "fullMemory")

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.base, order: 0)) } == "none")

            // Order 9 is available again only if the free walked all nine merges
            // back up. A missed merge leaves the arena permanently fragmented.
            let whole = allocated(ram.buddy, bytes: 512 * Int(Self.pageSize))
            #expect(whole?.address == ram.base)
            #expect(whole?.order   == 9)
        }
    }


    @Test("a request past the largest block or below zero is refused on sight")
    func orderBounds() {
        withHostRAM(pages: 512) { ram in
            ram.donateAll()

            #expect(refusal { _ = try ram.buddy.alloc(Self.largestBlock + 1) } == "bytesNotValid")
            #expect(refusal { _ = try ram.buddy.alloc(-1) }                    == "bytesNotValid")

            // An order the arena is too small for is exhaustion and not a bad
            // argument: the request is nameable, the memory is not there.
            #expect(refusal { _ = try ram.buddy.alloc(Self.largestBlock) } == "fullMemory")
        }
    }


    @Test("a block starting at the end of RAM is not a block")
    func rejectsAddressAtRamEnd() {
        withHostRAM(pages: 512) { ram in
            ram.donateAll()

            // `ramEnd` is exclusive. Accepting it would index one past the bitmap
            // and one past the frame metadata array.
            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.end, order: 0)) } == "addressInvalid")
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.end, to: ram.end + Self.pageSize) } == "addressInvalid")

            // A backwards range is its own refusal, so a caller that swapped the
            // two arguments is told which mistake it made.
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.page(4), to: ram.page(2)) } == "addressRangeInvalid")
        }
    }


    @Test("a block that would overrun the end of RAM is refused")
    func rejectsBlockOverrunningRam() {
        // Three pages: the arena is not a whole power of two, so the last page has
        // an aligned order-1 start whose block runs past the end of RAM.
        withHostRAM(pages: 3) { ram in
            ram.donateAll()

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.page(2), order: 1)) } == "addressInvalid")
            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.base,    order: 2)) } == "addressInvalid")
        }
    }


    @Test("a block whose buddy lies outside RAM is not merged past the end")
    func buddyOutsideRam() {
        // The donation of three pages is an order-1 block at page 0 and an order-0
        // block at page 2, whose buddy address is page 3: outside the arena.
        withHostRAM(pages: 3) { ram in
            ram.donateAll()

            let tail = allocated(ram.buddy, bytes: Int(Self.pageSize))
            #expect(tail?.address == ram.page(2))

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.page(2), order: 0)) } == "none")

            // A merge with the buddy it cannot have would leave order 1 holding a
            // block at page 2, running one page past RAM.
            let pair = allocated(ram.buddy, bytes: 2 * Int(Self.pageSize))
            #expect(pair?.address == ram.base)
            #expect(refusal { _ = try ram.buddy.alloc(2 * Int(Self.pageSize)) } == "fullMemory")

            let last = allocated(ram.buddy, bytes: Int(Self.pageSize))
            #expect(last?.address == ram.page(2))
        }
    }


    @Test("freeing a block that is already free is refused as a double free")
    func doubleFree() {
        withHostRAM(pages: 512) { ram in
            ram.donateAll()

            let page = allocated(ram.buddy, bytes: Int(Self.pageSize))
            #expect(page?.address == ram.base)

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.base, order: 0)) } == "none")
            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.base, order: 0)) } == "doubleFreeInvalid")
        }
    }


    @Test("an exhausted arena refuses the next page and serves it again after a free")
    func exhaustion() {
        withHostRAM(pages: 4) { ram in
            ram.donateAll()

            var handed: [PhysicalAddress] = []
            for _ in 0..<4 {
                guard let page = allocated(ram.buddy, bytes: Int(Self.pageSize)) else { break }
                handed.append(page.address)
            }

            #expect(handed.count == 4)
            #expect(Set(handed).count == 4)
            #expect(refusal { _ = try ram.buddy.alloc(Int(Self.pageSize)) } == "fullMemory")

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: handed[1], order: 0)) } == "none")

            let reused = allocated(ram.buddy, bytes: Int(Self.pageSize))
            #expect(reused?.address == handed[1])
        }
    }
}


/// The address and order one allocation produced, `nil` when it was refused.
///
/// `PhysicalPage` is non-copyable, so a bare `try? alloc` cannot be read twice: an
/// `#expect` on `page?.address` consumes it. This copies the two fields out and
/// lets the page go.
func allocated(
    _ allocator: BuddyAllocator,
    bytes      : Int
) -> (address: PhysicalAddress, order: UInt8)? {
    guard let page = try? allocator.alloc(bytes) else { return nil }

    return (page.address, page.order)
}
