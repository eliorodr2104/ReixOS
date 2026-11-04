//
//  BuddyNestedFreeTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport

/// `BuddyAllocator.free` refusing a block with a free block nested inside it
/// past its first frame, and the vector scan of the head bitmap behind that
/// check and behind donation.
///
/// Each allocator here keeps its bitmap at a chosen skew from a 16-byte
/// boundary, every skew from 0 to 15, so the aligned vector body, the byte-wise
/// head and tail around it and the bit-level edges of a partly covered byte are
/// all reached from every starting alignment.
@Suite("Buddy nested free blocks")
struct BuddyNestedFreeTests {

    private static let page: UInt64 = 4096


    @Test("a free covering a free block nested past its first frame is refused, every order and position")
    func nestedFreeRefused() {
        for skew in 0..<16 {
            withSkewedBuddy(pages: 4096, skew: skew) { buddy, _ in
                let initial = shape(buddy)

                for order in UInt8(1)...11 {
                    let head = try! buddy.alloc(Int(Self.page) << Int(order)).address
                    let frames = 1 << Int(order)

                    for position in Self.positions(frames: frames) {
                        let nested = head + UInt64(position) * Self.page
                        try! buddy.free(PhysicalPage(address: nested, order: 0))

                        let before = shape(buddy)
                        #expect(
                            refusal { try buddy.free(PhysicalPage(address: head, order: order)) }
                                == "doubleFreeInvalid",
                            "skew \(skew) order \(order) position \(position)"
                        )
                        #expect(shape(buddy) == before, "skew \(skew) order \(order) position \(position)")

                        let back = try! buddy.alloc(Int(Self.page)).address
                        #expect(back == nested)
                    }

                    // With nothing nested the same block frees and merges home.
                    #expect(refusal { try buddy.free(PhysicalPage(address: head, order: order)) } == "none")
                    #expect(buddyViolations(buddy).isEmpty)
                }
                #expect(shape(buddy) == initial, "skew \(skew)")
            }
        }
    }


    @Test("a larger free block nested inside is refused as well as a single frame")
    func nestedLargerBlockRefused() {
        withSkewedBuddy(pages: 4096, skew: 3) { buddy, _ in
            let head = try! buddy.alloc(Int(Self.page) << 11).address

            for order in UInt8(1)...10 {
                // The upper half's last aligned sub-block of this order.
                let inner = head + (Self.page << 11) - (Self.page << UInt64(order))
                try! buddy.free(PhysicalPage(address: inner, order: order))
                #expect(refusal { try buddy.free(PhysicalPage(address: head, order: 11)) } == "doubleFreeInvalid")
                let back = try! buddy.alloc(Int(Self.page) << Int(order)).address
                #expect(back == inner)
            }
            #expect(refusal { try buddy.free(PhysicalPage(address: head, order: 11)) } == "none")
            #expect(buddyViolations(buddy).isEmpty)
        }
    }


    @Test("a free block just past the end or just before the start is not nested")
    func neighboursAreNotNested() {
        for skew in [0, 7, 15] {
            withSkewedBuddy(pages: 4096, skew: skew) { buddy, _ in
                // Four order-2 blocks in a row; free the outer two, then the middle
                // pair must still free (and merge) without a refusal.
                let blocks = (0..<4).map { _ in try! buddy.alloc(Int(Self.page) << 2).address }.sorted()
                for address in [blocks[0], blocks[3]] {
                    try! buddy.free(PhysicalPage(address: address, order: 2))
                }
                for address in [blocks[1], blocks[2]] {
                    #expect(refusal { try buddy.free(PhysicalPage(address: address, order: 2)) } == "none",
                            "skew \(skew)")
                }
                #expect(buddyViolations(buddy).isEmpty)
            }
        }
    }


    @Test("the vector scan agrees with a bit-by-bit scan for every range shape and bitmap skew")
    func scanMatchesReference() {
        for skew in 0..<16 {
            withSkewedBuddy(pages: 2048, skew: skew, donate: false) { buddy, ram in
                // Sparse isolated frames, so most ranges are empty and the vector
                // body runs, plus a cluster at bit and byte edges.
                var rng = SplitMix64(seed: 0xB17_5CA0 + UInt64(skew))
                var frames: Set<Int> = [127, 128, 129, 1023, 2047]
                while frames.count < 24 { frames.insert(rng.below(2048)) }
                for frame in frames.sorted() {
                    _ = try? buddy.addFreeRange(from: ram.page(frame), to: ram.page(frame) + Self.page)
                }

                var heads = [Bool](repeating: false, count: 2048)
                for address in buddy.freeState.heads { heads[Int((address - ram.base) / Self.page)] = true }
                var prefix = [0]
                for head in heads { prefix.append(prefix.last! + (head ? 1 : 0)) }

                var lengths = Array(1...20) + [63, 64, 65, 127, 128, 129, 255, 256, 257, 1000, 2048]
                lengths += (0..<8).map { _ in 1 + rng.below(2048) }
                for start in 0..<300 {
                    for length in lengths where start + length <= 2048 {
                        let expected = prefix[start + length] - prefix[start] > 0
                        let actual = buddy.hasFreeHead(
                            from: UInt64(start) * Self.page,
                            to  : UInt64(start + length) * Self.page
                        )
                        #expect(actual == expected, "skew \(skew) frames \(start)..<\(start + length)")
                        if actual != expected { return }
                    }
                }
                #expect(!buddy.hasFreeHead(from: 0, to: 0))
                #expect(!buddy.hasFreeHead(from: 5 * Self.page, to: 5 * Self.page))
            }
        }
    }


    @Test("donation is refused when a free head sits on its last frame and accepted one frame short")
    func donationEdges() {
        for skew in [0, 1, 8, 15] {
            withSkewedBuddy(pages: 2048, skew: skew, donate: false) { buddy, ram in
                for head in [9, 135, 1031] {
                    try! buddy.addFreeRange(from: ram.page(head), to: ram.page(head) + Self.page)

                    // Ends on the head's frame: refused, nothing written.
                    let before = shape(buddy)
                    #expect(refusal { try buddy.addFreeRange(from: ram.page(head - 9), to: ram.page(head + 1)) }
                                == "doubleFreeInvalid", "skew \(skew) head \(head)")
                    #expect(shape(buddy) == before)

                    // Ends one frame short of it: accepted.
                    #expect(refusal { try buddy.addFreeRange(from: ram.page(head - 9), to: ram.page(head)) } == "none",
                            "skew \(skew) head \(head)")
                }
                #expect(buddyViolations(buddy).isEmpty)
            }
        }
    }


    // MARK: - Helpers

    /// Positions of a nested frame inside a block of `frames` frames: every
    /// frame for small blocks; for large ones the first and last after the head,
    /// both sides of each byte and 16-byte boundary, and the middle.
    private static func positions(frames: Int) -> [Int] {
        guard frames > 32 else { return Array(1..<frames) }
        let edges = [1, 2, 7, 8, 9, 15, 16, 17, 127, 128, 129, 255, 256, 257,
                     frames / 2 - 1, frames / 2, frames / 2 + 1, frames - 9, frames - 8, frames - 2, frames - 1]
        return Array(Set(edges.filter { $0 >= 1 && $0 < frames })).sorted()
    }


    /// A `BuddyAllocator` over `ram`'s arena whose head bitmap starts `skew`
    /// bytes past a 16-byte boundary. `ram.buddy` is never used alongside it.
    private func withSkewedBuddy(
        pages : Int,
        skew  : Int,
        donate: Bool = true,
        _ body: (BuddyAllocator, HostRAM) -> Void
    ) {
        withHostRAM(pages: pages) { ram in
            let bitmap = UnsafeMutableRawPointer.allocate(byteCount: pages / 8 + 64, alignment: 16)
            let lists  = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 16)
            defer { bitmap.deallocate(); lists.deallocate() }

            let buddy = BuddyAllocator(
                start           : ram.base,
                size            : ram.size,
                bitmapAddress   : PhysicalAddress(UInt(bitPattern: bitmap + skew)),
                freeListsAddress: PhysicalAddress(UInt(bitPattern: lists))
            )
            if donate { try! buddy.addFreeRange(from: ram.base, to: ram.end) }
            body(buddy, ram)
        }
    }
}
