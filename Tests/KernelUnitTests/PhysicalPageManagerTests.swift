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
/// What is staged: the RAM and metadata are host allocations. Narrow validation
/// tests use the zeroed manager shell, while allocation and coalescing tests install
/// a manager backed by the real buddy through `HostRAM.installLiveManager()`.
///
/// No global state, so this suite is parallel safe on its own. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("Physical page manager")
struct PhysicalPageManagerTests {

    @Test("an address outside RAM reports no references instead of reading past the array")
    func boundsOnRefCount() {
        withHostRAM(pages: 8) { ram in
            // `address - ramStart` underflows below the base and indexes off the
            // end at or past `ramEnd`. Both read as 0, which COW refuses as invalid.
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
            #expect(refusal { try ram.ppm.pointee.retain(ram.end) } == "invalidFrameAddress")
            #expect(refusal { try ram.ppm.pointee.retain(ram.base - 4096) } == "invalidFrameAddress")
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
            #expect(refusal { try ram.ppm.pointee.release(ram.end) }         == "invalidFrameAddress")
            #expect(refusal { try ram.ppm.pointee.release(ram.base - 4096) } == "invalidFrameAddress")
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
            ram.setFrame(
                FrameInfo(refCount: 1, order: 0, flags: [.kernel, .allocatorOwned]),
                at: ram.page(6)
            )

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

            // A kernel frame is not: it passes the protection check, but this staged
            // manager has no matching allocation accounting.
            #expect(refusal {
                try ram.ppm.pointee.freeOwnedKernelPage(PhysicalPage(address: ram.page(6), order: 0))
            } == "metadataInconsistency")
        }
    }


    @Test("invalid addresses and block shapes leave all PMM state byte-identical")
    func rejectedInputsAreAtomic() throws {
        try withLiveRAM(pages: 16) { ram in
            let block = try ram.ppm.pointee.alloc(8192)
            try ram.ppm.pointee.retain(block.address)
            let before = ram.pmmStateSnapshot()

            #expect(refusal { try ram.ppm.pointee.retain(block.address + 1) } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { try ram.ppm.pointee.release(block.address + 1) } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: block.address + 1, order: block.order))
            } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { try ram.ppm.pointee.release(block.address + 4096) } == "frameNotBlockHead")
            #expect(ram.pmmStateSnapshot() == before)
            #expect(ram.ppm.pointee.refCount(of: block.address + 4096) == 0)
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: block.address, order: 0))
            } == "pageOrderMismatch")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: block.address, order: UInt8.max))
            } == "pageOrderMismatch")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { try ram.ppm.pointee.release(ram.end) } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { try ram.ppm.pointee.release(ram.base - 1) } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { try ram.ppm.pointee.release(UInt64.max) } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("a partial RAM tail never indexes a nonexistent metadata record")
    func partialTailIsOutsideMetadata() {
        withHostRAM(pages: 1) { ram in
            ram.installLiveManager(reportedRAMSize: 4097)
            ram.setOwnedFrame(at: ram.base, refCount: 1)

            let tail   = ram.base + 4096
            let before = ram.pmmStateSnapshot()

            #expect(ram.ppm.pointee.refCount(of: tail) == 0)
            #expect(refusal { try ram.ppm.pointee.retain(tail) } == "invalidFrameAddress")
            #expect(refusal { try ram.ppm.pointee.release(tail) } == "invalidFrameAddress")
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: tail, order: 0))
            } == "invalidFrameAddress")
            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("a valid address with no metadata refuses before dereferencing")
    func missingMetadataIsSafe() {
        withHostRAM(pages: 2) { ram in
            ram.setOwnedFrame(at: ram.base, refCount: 2)
            ram.ppm.pointee.framesMetadata = nil
            defer { ram.ppm.pointee.framesMetadata = ram.frames }
            let before = ram.pmmStateSnapshot()

            #expect(ram.ppm.pointee.refCount(of: ram.base) == 0)
            #expect(refusal { try ram.ppm.pointee.retain(ram.base) } == "metadataInconsistency")
            #expect(refusal { try ram.ppm.pointee.release(ram.base) } == "metadataInconsistency")
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.base, order: 0))
            } == "metadataInconsistency")
            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("a head whose order cannot fit at its address is rejected atomically")
    func incoherentBlockExtent() {
        withHostRAM(pages: 8) { ram in
            ram.setFrame(
                FrameInfo(refCount: 2, order: 1, flags: .allocatorOwned),
                at: ram.page(1)
            )
            let before = ram.pmmStateSnapshot()

            #expect(refusal { try ram.ppm.pointee.release(ram.page(1)) } == "metadataInconsistency")
            #expect(ram.pmmStateSnapshot() == before)
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.page(1), order: 1))
            } == "metadataInconsistency")
            #expect(ram.pmmStateSnapshot() == before)

            ram.setFrame(
                FrameInfo(refCount: 2, order: 4, flags: .allocatorOwned),
                at: ram.base
            )
            let oversized = ram.pmmStateSnapshot()

            #expect(ram.ppm.pointee.refCount(of: ram.base) == 0)
            #expect(ram.pmmStateSnapshot() == oversized)
            #expect(refusal { try ram.ppm.pointee.retain(ram.base) } == "metadataInconsistency")
            #expect(ram.pmmStateSnapshot() == oversized)
            #expect(refusal { try ram.ppm.pointee.release(ram.base) } == "metadataInconsistency")
            #expect(ram.pmmStateSnapshot() == oversized)
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: ram.base, order: 4))
            } == "metadataInconsistency")
            #expect(ram.pmmStateSnapshot() == oversized)
        }
    }


    @Test("references require allocator ownership, a live head and counter capacity")
    func retainRequiresALiveHead() throws {
        try withLiveRAM(pages: 16) { ram in
            let freeAddress = ram.page(15)
            var before      = ram.pmmStateSnapshot()

            #expect(refusal { try ram.ppm.pointee.retain(freeAddress) } == "frameNotAllocated")
            #expect(ram.pmmStateSnapshot() == before)

            ram.setFrame(
                FrameInfo(refCount: 1, order: 0, flags: .none),
                at: freeAddress
            )
            before = ram.pmmStateSnapshot()
            #expect(ram.ppm.pointee.refCount(of: freeAddress) == 0)
            #expect(refusal { try ram.ppm.pointee.retain(freeAddress) } == "frameNotAllocated")
            #expect(ram.pmmStateSnapshot() == before)
            #expect(refusal { try ram.ppm.pointee.release(freeAddress) } == "frameNotAllocated")
            #expect(ram.pmmStateSnapshot() == before)
            #expect(refusal {
                try ram.ppm.pointee.free(PhysicalPage(address: freeAddress, order: 0))
            } == "frameNotAllocated")
            #expect(ram.pmmStateSnapshot() == before)

            ram.setFrame(
                FrameInfo(refCount: 1, order: 0, flags: .reserved),
                at: freeAddress
            )
            before = ram.pmmStateSnapshot()
            #expect(refusal { try ram.ppm.pointee.retain(freeAddress) } == "protectedMemoryViolation")
            #expect(ram.pmmStateSnapshot() == before)

            let block = try ram.ppm.pointee.alloc(8192)
            before = ram.pmmStateSnapshot()
            #expect(refusal { try ram.ppm.pointee.retain(block.address + 4096) } == "frameNotBlockHead")
            #expect(ram.pmmStateSnapshot() == before)

            var head = ram.frame(at: block.address)
            head.refCount = 0
            ram.setFrame(head, at: block.address)
            before = ram.pmmStateSnapshot()
            #expect(refusal { try ram.ppm.pointee.retain(block.address) } == "invalidRefCount")
            #expect(ram.pmmStateSnapshot() == before)

            head.refCount = UInt32.max - 1
            ram.setFrame(head, at: block.address)
            try ram.ppm.pointee.retain(block.address)
            #expect(ram.ppm.pointee.refCount(of: block.address) == UInt32.max)
            before = ram.pmmStateSnapshot()
            #expect(refusal { try ram.ppm.pointee.retain(block.address) } == "referenceCountOverflow")
            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("the last release clears the whole block and restores coalescing")
    func finalReleaseClearsAndCoalesces() throws {
        try withLiveRAM(pages: 16) { ram in
            let block = try ram.ppm.pointee.alloc(8192)
            #expect(ram.ppm.pointee.allocatedPages == 2)

            try ram.ppm.pointee.retain(block.address)
            try ram.ppm.pointee.release(block.address)
            #expect(ram.ppm.pointee.refCount(of: block.address) == 1)
            #expect(ram.ppm.pointee.allocatedPages == 2)

            try ram.ppm.pointee.release(block.address)
            #expect(ram.ppm.pointee.allocatedPages == 0)
            #expect(ram.frame(at: block.address).refCount == 0)
            #expect(ram.frame(at: block.address).flags == .none)
            #expect(ram.frame(at: block.address + 4096).order == 0)
            #expect(ram.frame(at: block.address + 4096).flags == .none)

            let freed = ram.pmmStateSnapshot()
            #expect(refusal { try ram.ppm.pointee.release(block.address) } == "frameNotAllocated")
            #expect(ram.pmmStateSnapshot() == freed)
            #expect(refusal { try ram.ppm.pointee.release(block.address + 4096) } == "frameNotAllocated")
            #expect(ram.pmmStateSnapshot() == freed)

            let whole = try ram.ppm.pointee.alloc(16 * 4096)
            #expect(whole.address == ram.base)
            #expect(whole.order == 4)
        }
    }


    @Test("invalid allocation requests and OOM preserve allocator state")
    func allocationFailureRollsBack() throws {
        try withLiveRAM(pages: 8) { ram in
            var before = ram.pmmStateSnapshot()
            #expect(refusal { _ = try ram.ppm.pointee.alloc(0) } == "allocationFailed")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { _ = try ram.ppm.pointee.alloc(-1) } == "allocationFailed")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal { _ = try ram.ppm.pointee.alloc(Int.max) } == "allocationFailed")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal {
                _ = try ram.ppm.pointee.alloc(4096, flag: .reserved)
            } == "invalidFlags")
            #expect(ram.pmmStateSnapshot() == before)

            #expect(refusal {
                _ = try ram.ppm.pointee.alloc(
                    4096,
                    flag: PhysicalPageFlags(rawValue: 1 << 7)
                )
            } == "invalidFlags")
            #expect(ram.pmmStateSnapshot() == before)

            _ = try ram.ppm.pointee.alloc(8 * 4096)
            before = ram.pmmStateSnapshot()
            #expect(refusal { _ = try ram.ppm.pointee.alloc(1) } == "allocationFailed")
            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("mixed allocation and reference transitions match a seeded model")
    func mixedStateMachine() throws {
        try withLiveRAM(pages: 64) { ram in
            struct Block {
                let address: PhysicalAddress
                let order  : UInt8
                var refs   : UInt32
            }

            var seed  : UInt64 = 0xC0FF_EE03_5EED_0001
            var blocks: [Block] = []

            func random() -> UInt64 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return seed
            }

            for _ in 0..<512 {
                let choice = random() % 100

                if blocks.isEmpty || choice < 42 {
                    let order = UInt8(random() % 4)
                    let bytes = 4096 << Int(order)
                    let before = ram.pmmStateSnapshot()

                    do {
                        let page = try ram.ppm.pointee.alloc(bytes)
                        blocks.append(Block(address: page.address, order: page.order, refs: 1))
                    } catch {
                        #expect(ram.pmmStateSnapshot() == before)
                    }

                } else {
                    let index = Int(random() % UInt64(blocks.count))

                    if choice < 70, blocks[index].refs < 4 {
                        try ram.ppm.pointee.retain(blocks[index].address)
                        blocks[index].refs += 1

                    } else {
                        try ram.ppm.pointee.release(blocks[index].address)
                        blocks[index].refs -= 1

                        if blocks[index].refs == 0 {
                            blocks.remove(at: index)
                        }
                    }
                }

                let expectedPages = blocks.reduce(UInt64(0)) {
                    $0 + (UInt64(1) << UInt64($1.order))
                }
                #expect(ram.ppm.pointee.allocatedPages == expectedPages)

                for block in blocks {
                    #expect(ram.ppm.pointee.refCount(of: block.address) == block.refs)
                }

                for first in blocks.indices {
                    let firstStart = blocks[first].address
                    let firstEnd   = firstStart + (4096 << UInt64(blocks[first].order))

                    for second in blocks.indices where second > first {
                        let secondStart = blocks[second].address
                        let secondEnd   = secondStart + (4096 << UInt64(blocks[second].order))
                        #expect(firstEnd <= secondStart || secondEnd <= firstStart)
                    }
                }
            }

            while let block = blocks.popLast() {
                for _ in 0..<block.refs {
                    try ram.ppm.pointee.release(block.address)
                }
            }

            #expect(ram.ppm.pointee.allocatedPages == 0)
            let whole = try ram.ppm.pointee.alloc(64 * 4096)
            #expect(whole.address == ram.base)
            #expect(whole.order == 6)
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


private func withLiveRAM(
    pages : Int,
    _ body: (HostRAM) throws -> Void
) throws {
    let ram = HostRAM(pages: pages)
    defer { ram.release() }

    guard ram.donateAll() else {
        Issue.record("could not donate host RAM to the buddy")
        return
    }
    ram.installLiveManager()

    try body(ram)
}
