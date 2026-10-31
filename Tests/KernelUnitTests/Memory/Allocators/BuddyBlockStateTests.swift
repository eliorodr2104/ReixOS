//
//  BuddyBlockStateTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport

/// The buddy allocator's per-block state: one head bit per free block, its order
/// in the block's own node, the block on that order's list. Every operation is
/// driven over a real host arena and followed by `buddyViolations`, which walks
/// the lists and the head bits and reports every way they disagree.
@Suite("Buddy block state")
struct BuddyBlockStateTests {

    private static let page: UInt64 = 4096
    private static let maxOrder: UInt8 = 11


    // MARK: - alloc

    @Test("a request rounds up to the smallest order that holds it")
    func allocRoundsUp() {
        withHostRAM(pages: 3000) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)

            let cases: [(bytes: Int, order: UInt8)] = [
                (0, 0), (1, 0), (4096, 0), (4097, 1), (8192, 1), (8193, 2),
                (3 * 4096, 2), (5 * 4096, 3), (2048 * 4096, 11),
            ]

            for (bytes, order) in cases {
                let block = allocated(ram.buddy, bytes: bytes)
                #expect(block?.order == order, "bytes \(bytes)")
                #expect(buddyViolations(ram.buddy).isEmpty)

                if let block {
                    #expect(refusal { try ram.buddy.free(PhysicalPage(address: block.address, order: block.order)) } == "none")
                }
                #expect(shape(ram.buddy) == initial)
            }
        }
    }


    @Test("every order from 0 to maxOrder is served aligned and comes back")
    func everyOrder() {
        withHostRAM(pages: 3000) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)

            for order in 0...Self.maxOrder {
                let block = allocated(ram.buddy, bytes: Int(Self.page << UInt64(order)))
                #expect(block?.order == order)
                #expect(block.map { ($0.address - ram.base) % (Self.page << UInt64(order)) } == 0)
                #expect(buddyViolations(ram.buddy, freePages: 3000 - (1 << Int(order))).isEmpty)

                if let block {
                    #expect(refusal { try ram.buddy.free(PhysicalPage(address: block.address, order: order)) } == "none")
                }
                #expect(shape(ram.buddy) == initial)
            }
        }
    }


    @Test("a size past the largest block or below zero is refused without a write")
    func allocBytesRefused() {
        withHostRAM(pages: 3000) { ram in
            ram.donateAll()
            let before = view(ram.buddy)

            for bytes in [(4096 << 11) + 1, -1, Int.max, Int.min] {
                #expect(refusal { _ = try ram.buddy.alloc(bytes) } == "bytesNotValid", "bytes \(bytes)")
                #expect(view(ram.buddy) == before)
            }
        }
    }


    @Test("an allocator that was never given memory is full for every size")
    func allocNothingDonated() {
        withHostRAM(pages: 8) { ram in
            #expect(refusal { _ = try ram.buddy.alloc(0) } == "fullMemory")
            #expect(refusal { _ = try ram.buddy.alloc(4096) } == "fullMemory")
            #expect(refusal { _ = try ram.buddy.alloc(4096 << 11) } == "fullMemory")
            #expect(ram.buddy.freeState.heads.isEmpty)
        }
    }


    @Test("a request larger than every free block is full while smaller ones are free")
    func allocTooLargeForWhatIsFree() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let before = view(ram.buddy)

            // 600 pages hold an order-9 block at most, so order 10 has nowhere to come from.
            #expect(refusal { _ = try ram.buddy.alloc(1024 * 4096) } == "fullMemory")
            #expect(view(ram.buddy) == before)
        }
    }


    @Test("an exhausted arena refuses, then serves its largest block again once drained")
    func exhaustionAndRecovery() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)

            var held: [PhysicalAddress] = []
            while let block = allocated(ram.buddy, bytes: 4096) { held.append(block.address) }

            #expect(held.count == 600)
            #expect(Set(held).count == 600)
            #expect(held.allSatisfy { $0 >= ram.base && $0 < ram.end })
            #expect(ram.buddy.freeState.heads.isEmpty)
            #expect(buddyViolations(ram.buddy, freePages: 0).isEmpty)

            let full = view(ram.buddy)
            #expect(refusal { _ = try ram.buddy.alloc(4096) } == "fullMemory")
            #expect(view(ram.buddy) == full)

            for address in held {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: address, order: 0)) } == "none")
            }

            #expect(shape(ram.buddy) == initial)
            #expect(allocated(ram.buddy, bytes: 512 * 4096)?.address == ram.base)
        }
    }


    @Test("a split leaves exactly one free buddy on each order it walked down")
    func splitState() {
        withHostRAM(pages: 512) { ram in
            ram.donateAll()

            #expect(allocated(ram.buddy, bytes: 4096)?.address == ram.base)

            var expected = [[PhysicalAddress]](repeating: [], count: 12)
            for order in 0..<9 { expected[order] = [ram.base + (Self.page << UInt64(order))] }

            #expect(shape(ram.buddy) == expected)
            #expect(ram.buddy.freeState.heads == expected.flatMap { $0 }.sorted())
            #expect(buddyViolations(ram.buddy, freePages: 511).isEmpty)
        }
    }


    // MARK: - free

    @Test("an exact double free is refused before any state changes")
    func doubleFreeExact() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let first  = allocated(ram.buddy, bytes: 4096)!
            let second = allocated(ram.buddy, bytes: 4096)!
            #expect(second.address == first.address + Self.page)

            // `second` is still held, so `first` stays a free order-0 head.
            #expect(refusal { try ram.buddy.free(PhysicalPage(address: first.address, order: 0)) } == "none")
            let before = view(ram.buddy)

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: first.address, order: 0)) } == "doubleFreeInvalid")
            #expect(view(ram.buddy) == before)
            #expect(buddyViolations(ram.buddy, freePages: 599).isEmpty)
        }
    }


    @Test("a frame inside a larger free block is refused as a double free")
    func doubleFreeInsideMergedBlock() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let before = view(ram.buddy)

            // The order-9 block at the base is free: every frame in it is already free.
            for (index, order) in [(0, UInt8(0)), (1, 0), (8, 3), (256, 8), (511, 0), (0, 9), (512, 6), (599, 0)] {
                #expect(refusal {
                    try ram.buddy.free(PhysicalPage(address: ram.page(index), order: order))
                } == "doubleFreeInvalid", "page \(index) order \(order)")
                #expect(view(ram.buddy) == before)
            }
        }
    }


    /// Regression: the per-page bitmap refused a double free only when every
    /// frame of the block was free, so a block whose first frame was free and
    /// whose second was held went back on a list over the held frame.
    @Test("a block whose first frame is free and second is held is refused")
    func partiallyFreeBlockRefused() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let first  = allocated(ram.buddy, bytes: 4096)!
            _          = allocated(ram.buddy, bytes: 4096)!

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: first.address, order: 0)) } == "none")
            let before = view(ram.buddy)

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: first.address, order: 1)) } == "doubleFreeInvalid")
            #expect(view(ram.buddy) == before)
            #expect(buddyViolations(ram.buddy, freePages: 599).isEmpty)
        }
    }


    @Test("an address that does not name a block in RAM is refused without a write")
    func freeAddressInvalid() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            while allocated(ram.buddy, bytes: 4096) != nil {}
            let before = view(ram.buddy)

            let cases: [(PhysicalAddress, UInt8, String)] = [
                (ram.base - Self.page, 0, "below RAM"),
                (ram.end,              0, "at the end of RAM"),
                (ram.end + Self.page,  0, "past RAM"),
                (ram.base + 1,         0, "not page aligned"),
                (ram.page(1),          1, "misaligned for its order"),
                (ram.page(4),          3, "misaligned for its order"),
                (ram.page(512),        9, "runs past the end of RAM"),
                (ram.page(592),        4, "runs past the end of RAM"),
                (ram.base - Self.page, 12, "outside RAM wins over a bad order"),
                (UInt64.max & ~0xFFF,  0, "top of the address space"),
            ]

            for (address, order, why) in cases {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: address, order: order)) } == "addressInvalid", "\(why)")
                #expect(view(ram.buddy) == before)
            }
        }
    }


    @Test("an order past maxOrder is refused for an address in RAM")
    func freeOrderInvalid() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            while allocated(ram.buddy, bytes: 4096) != nil {}
            let before = view(ram.buddy)

            for order: UInt8 in [12, 15, 255] {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.base, order: order)) } == "pageOrderInvalid")
                #expect(view(ram.buddy) == before)
            }
        }
    }


    @Test("the first and last frame of RAM free and merge like any other")
    func firstAndLastFrame() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)
            var held: [PhysicalAddress] = []
            while let block = allocated(ram.buddy, bytes: 4096) { held.append(block.address) }

            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.page(599), order: 0)) } == "none")
            #expect(refusal { try ram.buddy.free(PhysicalPage(address: ram.base, order: 0)) } == "none")
            #expect(buddyViolations(ram.buddy, freePages: 2).isEmpty)
            #expect(ram.buddy.freeState.heads == [ram.base, ram.page(599)])

            for address in held where address != ram.base && address != ram.page(599) {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: address, order: 0)) } == "none")
            }
            #expect(shape(ram.buddy) == initial)
        }
    }


    @Test("a RAM span that wraps the address space refuses every address")
    func wrappingSpan() {
        let bitmap = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        let lists  = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16)
        defer { bitmap.deallocate(); lists.deallocate() }

        let start = (UInt64.max - 8 * Self.page) & ~0xFFF
        let buddy = BuddyAllocator(
            start           : start,
            size            : 64 * Self.page,
            bitmapAddress   : PhysicalAddress(UInt(bitPattern: bitmap)),
            freeListsAddress: PhysicalAddress(UInt(bitPattern: lists))
        )

        #expect(refusal { try buddy.addFreeRange(from: start, to: start + Self.page) } == "addressInvalid")
        #expect(refusal { try buddy.free(PhysicalPage(address: start, order: 0)) } == "addressInvalid")
        #expect(refusal { _ = try buddy.alloc(4096) } == "fullMemory")
    }


    // MARK: - addFreeRange

    @Test("a RAM size that is not a power of two donates its largest aligned blocks", arguments: [
        (1,    [(0, 0)]),
        (3,    [(1, 0), (0, 2)]),
        (600,  [(9, 0), (6, 512), (4, 576), (3, 592)]),
        (3000, [(11, 0), (9, 2048), (8, 2560), (7, 2816), (5, 2944), (4, 2976), (3, 2992)]),
        (4096, [(11, 0), (11, 2048)]),
    ])
    func donationShape(pages: Int, blocks: [(Int, Int)]) {
        withHostRAM(pages: pages) { ram in
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.base, to: ram.end) } == "none")

            var expected = [[PhysicalAddress]](repeating: [], count: 12)
            for (order, page) in blocks { expected[order].append(ram.page(page)) }

            #expect(shape(ram.buddy) == expected)
            #expect(buddyViolations(ram.buddy, freePages: pages).isEmpty)
        }
    }


    @Test("raw bounds are rounded inward to whole pages")
    func donationRoundsInward() {
        withHostRAM(pages: 16) { ram in
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.base + 1, to: ram.page(7) + 4095) } == "none")

            var expected = [[PhysicalAddress]](repeating: [], count: 12)
            expected[0] = [ram.page(1), ram.page(6)]
            expected[1] = [ram.page(2), ram.page(4)]

            #expect(shape(ram.buddy) == expected)
            #expect(buddyViolations(ram.buddy, freePages: 6).isEmpty)
        }
    }


    @Test("a range inside one page donates nothing and is not an error")
    func donationInsideOnePage() {
        withHostRAM(pages: 16) { ram in
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.base + 1, to: ram.base + 4095) } == "none")
            #expect(ram.buddy.freeState.heads.isEmpty)
            #expect(refusal { _ = try ram.buddy.alloc(4096) } == "fullMemory")
        }
    }


    @Test("a range that leaves RAM or runs backwards is refused without a write")
    func donationRefusals() {
        withHostRAM(pages: 16) { ram in
            ram.donate(from: ram.page(8), to: ram.end)
            let before = view(ram.buddy)

            let cases: [(PhysicalAddress, PhysicalAddress, String)] = [
                (ram.base - Self.page, ram.page(2),        "addressInvalid"),
                (ram.end,              ram.end + Self.page, "addressInvalid"),
                (ram.base,             ram.end + 1,        "addressInvalid"),
                (ram.page(2),          ram.page(2),        "addressRangeInvalid"),
                (ram.page(4),          ram.page(2),        "addressRangeInvalid"),
            ]

            for (from, to, expected) in cases {
                #expect(refusal { try ram.buddy.addFreeRange(from: from, to: to) } == expected)
                #expect(view(ram.buddy) == before)
            }
        }
    }


    /// Regression: a re-donation used to be inserted again, linking a node that
    /// was already on a list and handing the same frames out twice.
    @Test("a range overlapping free memory anywhere is refused whole")
    func donationOverlapRefused() {
        withHostRAM(pages: 16) { ram in
            ram.donate(from: ram.base, to: ram.page(8))
            ram.donate(from: ram.page(12), to: ram.end)
            let before = view(ram.buddy)

            let cases: [(Int, Int, String)] = [
                (0, 8,  "the same range again"),
                (4, 12, "starts inside a free block"),
                (8, 16, "a free block nested inside its one chunk"),
                (10, 13, "ends inside a free block"),
                (0, 16, "covers free memory at both ends"),
            ]

            for (from, to, why) in cases {
                #expect(refusal { try ram.buddy.addFreeRange(from: ram.page(from), to: ram.page(to)) } == "doubleFreeInvalid", "\(why)")
                #expect(view(ram.buddy) == before)
            }

            #expect(refusal { try ram.buddy.addFreeRange(from: ram.page(8), to: ram.page(12)) } == "none")

            var expected = [[PhysicalAddress]](repeating: [], count: 12)
            expected[4] = [ram.base]
            #expect(shape(ram.buddy) == expected)
            #expect(buddyViolations(ram.buddy, freePages: 16).isEmpty)
        }
    }


    @Test("the first and last frame of RAM can be donated alone")
    func donationEdges() {
        withHostRAM(pages: 600) { ram in
            #expect(refusal { try ram.buddy.addFreeRange(from: ram.page(599), to: ram.end) } == "none")
            #expect(allocated(ram.buddy, bytes: 4096)?.address == ram.page(599))

            #expect(refusal { try ram.buddy.addFreeRange(from: ram.base, to: ram.page(1)) } == "none")
            #expect(allocated(ram.buddy, bytes: 4096)?.address == ram.base)
            #expect(refusal { _ = try ram.buddy.alloc(4096) } == "fullMemory")
        }
    }


    @Test("pieces donated in any order coalesce to the whole-RAM shape")
    func donationPiecesCoalesce() {
        withHostRAM(pages: 600) { reference in
            reference.donateAll()
            let whole = shape(reference.buddy)

            withHostRAM(pages: 600) { ram in
                let cuts = [0, 1, 7, 64, 65, 300, 511, 512, 513, 599, 600]
                var pieces: [(Int, Int)] = []
                for index in 1..<cuts.count { pieces.append((cuts[index - 1], cuts[index])) }

                var rng = SplitMix64(seed: 0x5EED_D0_4A7E)
                for index in pieces.indices.reversed() {
                    pieces.swapAt(index, rng.below(index + 1))
                }

                for (from, to) in pieces {
                    #expect(refusal { try ram.buddy.addFreeRange(from: ram.page(from), to: ram.page(to)) } == "none")
                    #expect(buddyViolations(ram.buddy).isEmpty)
                }

                // The pages are offsets from two different arenas, so compare relative.
                #expect(relative(shape(ram.buddy), ram.base) == relative(whole, reference.base))
            }
        }
    }


    // MARK: - Coalescing

    @Test("order-0 frees rebuild the exact initial shape whatever their order", arguments: [
        "ascending", "descending", "interleaved", "random",
    ])
    func coalesceOrders(sequence: String) {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)

            var held: [PhysicalAddress] = []
            while let block = allocated(ram.buddy, bytes: 4096) { held.append(block.address) }
            held.sort()

            switch sequence {
                case "descending":
                    held.reverse()
                case "interleaved":
                    held = stride(from: 0, to: held.count, by: 2).map { held[$0] }
                         + stride(from: 1, to: held.count, by: 2).map { held[$0] }
                case "random":
                    var rng = SplitMix64(seed: 0xC0A1_E5CE)
                    for index in held.indices.reversed() { held.swapAt(index, rng.below(index + 1)) }
                default:
                    break
            }

            for (step, address) in held.enumerated() {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: address, order: 0)) } == "none")
                let violations = buddyViolations(ram.buddy, freePages: step + 1)
                #expect(violations.isEmpty, "step \(step): \(violations)")
                if !violations.isEmpty { return }
            }

            #expect(shape(ram.buddy) == initial)
        }
    }


    @Test("mixed-order blocks freed in a seeded order rebuild the initial shape")
    func coalesceMixedOrders() {
        withHostRAM(pages: 3000) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)
            var rng = SplitMix64(seed: 0x0DDB_A11)

            var held: [(PhysicalAddress, UInt8)] = []
            var misses = 0
            while misses < 8 {
                if let block = allocated(ram.buddy, bytes: 4096 << rng.below(7)) {
                    held.append((block.address, block.order))
                } else { misses += 1 }
            }
            while let block = allocated(ram.buddy, bytes: 4096) { held.append((block.address, block.order)) }
            #expect(buddyViolations(ram.buddy, freePages: 0, live: held).isEmpty)

            for index in held.indices.reversed() { held.swapAt(index, rng.below(index + 1)) }
            while let (address, order) = held.popLast() {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: address, order: order)) } == "none")
                let violations = buddyViolations(ram.buddy, live: held)
                #expect(violations.isEmpty, "\(violations)")
                if !violations.isEmpty { return }
            }

            #expect(shape(ram.buddy) == initial)
        }
    }


    // MARK: - Seeded stress

    @Test("a seeded stress keeps the lists, the head bits and the held blocks in agreement")
    func seededStress() {
        withHostRAM(pages: 600) { ram in
            ram.donateAll()
            let initial = shape(ram.buddy)

            var rng   = SplitMix64(seed: 0x00B0_DD1E_57E5)
            var live  : [(PhysicalAddress, UInt8)] = []
            var stale : [(PhysicalAddress, UInt8)] = []
            var counts = [String: Int]()

            for step in 0..<5000 {
                let choice = rng.below(100)
                let before = view(ram.buddy)

                if choice < 50 {
                    let order = UInt8(rng.below(7))
                    if let block = allocated(ram.buddy, bytes: Int(Self.page << UInt64(order))) {
                        #expect(block.order == order)
                        live.append((block.address, block.order))
                        counts["alloc", default: 0] += 1
                    } else {
                        // Full is only true when no list at this order or above holds a block.
                        let lists = ram.buddy.freeState.lists
                        #expect(lists[Int(order)...].allSatisfy { $0.isEmpty }, "step \(step)")
                        #expect(view(ram.buddy) == before)
                        counts["full", default: 0] += 1
                    }

                } else if choice < 90, !live.isEmpty {
                    let block = live.remove(at: rng.below(live.count))
                    #expect(refusal { try ram.buddy.free(PhysicalPage(address: block.0, order: block.1)) } == "none")
                    stale.append(block)
                    counts["free", default: 0] += 1

                } else if choice < 95, !stale.isEmpty,
                          case let block = stale[rng.below(stale.count)],
                          !live.contains(where: { covers($0, block.0) }) {
                    // Its first frame is not held by anyone, so it can only be free.
                    #expect(refusal { try ram.buddy.free(PhysicalPage(address: block.0, order: block.1)) } == "doubleFreeInvalid")
                    #expect(view(ram.buddy) == before)
                    counts["double", default: 0] += 1

                } else {
                    let address = ram.base + UInt64(rng.below(600)) * Self.page + 2048
                    #expect(refusal { try ram.buddy.free(PhysicalPage(address: address, order: 0)) } == "addressInvalid")
                    #expect(view(ram.buddy) == before)
                    counts["invalid", default: 0] += 1
                }

                let held       = live.reduce(0) { $0 + (1 << Int($1.1)) }
                let violations = buddyViolations(ram.buddy, freePages: 600 - held, live: live)
                #expect(violations.isEmpty, "step \(step): \(violations)")
                if !violations.isEmpty { return }
            }

            for block in live {
                #expect(refusal { try ram.buddy.free(PhysicalPage(address: block.0, order: block.1)) } == "none")
            }
            #expect(shape(ram.buddy) == initial)

            // Every kind of step has to have happened for the run to mean anything.
            #expect(["alloc", "full", "free", "double", "invalid"].allSatisfy { counts[$0, default: 0] > 50 }, "\(counts)")
        }
    }
}


// MARK: - Invariant checker

/// Everything about `buddy`'s free state that disagrees with itself, empty when
/// sound. Checks, in this order: list links; each node on the list of its own
/// order, aligned, inside RAM and with its head bit set; no head bit without a
/// node; no two free blocks overlapping; no two free buddies left unmerged.
///
/// With `freePages` it also checks the free total, and with `live` that the held
/// blocks and the free ones never share a frame.
func buddyViolations(
    _ buddy  : BuddyAllocator,
    freePages: Int? = nil,
    live     : [(PhysicalAddress, UInt8)] = []
) -> [String] {
    let state = buddy.freeState
    let page  = UInt64(4096)
    let end   = state.start + state.size
    var found : [String] = []

    if state.brokenLinks != 0 { found.append("\(state.brokenLinks) broken links") }

    var blocks: [(address: PhysicalAddress, order: UInt8)] = []
    let heads  = Set(state.heads)

    for (listOrder, list) in state.lists.enumerated() {
        for (address, order) in list {
            let bytes = page << UInt64(listOrder)

            if order != UInt8(listOrder) { found.append("0x\(String(address, radix: 16)) on list \(listOrder) says order \(order)") }
            if address < state.start || address >= end { found.append("0x\(String(address, radix: 16)) outside RAM") ; continue }
            if (address - state.start) % bytes != 0 { found.append("0x\(String(address, radix: 16)) misaligned for order \(listOrder)") }
            if bytes > end - address { found.append("0x\(String(address, radix: 16)) order \(listOrder) runs past RAM") }
            if !heads.contains(address) { found.append("0x\(String(address, radix: 16)) listed without a head bit") }

            blocks.append((address, UInt8(listOrder)))
        }
    }

    if blocks.count != heads.count || Set(blocks.map(\.address)).count != blocks.count {
        found.append("\(heads.count) head bits for \(blocks.count) listed blocks")
    }

    let sorted = blocks.sorted { $0.address < $1.address }
    for index in sorted.indices.dropFirst() {
        let previous = sorted[index - 1]
        if previous.address + (page << UInt64(previous.order)) > sorted[index].address {
            found.append("free blocks at 0x\(String(previous.address, radix: 16)) and 0x\(String(sorted[index].address, radix: 16)) overlap")
        }
    }

    let listed = Set(blocks.map { "\($0.address)/\($0.order)" })
    for (address, order) in blocks where order < state.maxOrder {
        let bytes = page << UInt64(order)
        let buddy = state.start + ((address - state.start) ^ bytes)
        if buddy + bytes <= end, listed.contains("\(buddy)/\(order)") {
            found.append("free buddies at 0x\(String(address, radix: 16)) order \(order) were not merged")
        }
    }

    let free = blocks.reduce(0) { $0 + (1 << Int($1.order)) }
    if let freePages, free != freePages { found.append("\(free) free pages, expected \(freePages)") }

    if !live.isEmpty {
        var owner = [UInt8](repeating: 0, count: Int(state.size / page))
        for (address, order) in blocks.map({ ($0.address, $0.order) }) + live {
            let first = Int((address - state.start) / page)
            for index in first..<(first + (1 << Int(order))) { owner[index] += 1 }
        }
        if let index = owner.firstIndex(where: { $0 > 1 }) {
            found.append("frame \(index) is both held and free")
        }
    }

    return found
}


/// Free blocks per order, sorted by address: the shape a coalesce must return to.
func shape(_ buddy: BuddyAllocator) -> [[PhysicalAddress]] {
    buddy.freeState.lists.map { list in list.map(\.address).sorted() }
}


/// The lists in link order with each node's recorded order, then the head bits:
/// equal before and after a call only if the call wrote nothing the buddy reads.
private func view(_ buddy: BuddyAllocator) -> [[UInt64]] {
    let state = buddy.freeState
    return state.lists.map { list in list.map { $0.address + UInt64($0.order) } } + [state.heads, [UInt64(state.brokenLinks)]]
}


private func relative(_ shape: [[PhysicalAddress]], _ base: PhysicalAddress) -> [[UInt64]] {
    shape.map { list in list.map { $0 - base } }
}


private func covers(_ block: (PhysicalAddress, UInt8), _ address: PhysicalAddress) -> Bool {
    address >= block.0 && address < block.0 + (4096 << UInt64(block.1))
}
