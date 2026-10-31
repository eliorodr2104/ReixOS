//
//  VMAListGapTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The gap search of the VMA list: the arithmetic at the top of the 64-bit
/// space, the alignments it can honour, and a seeded history checked against
/// `reference`, a brute-force search over the chain.
@Suite("VMA list gap search")
struct VMAListGapTests {

    private static let page: UInt64 = 4096
    private static let base: VirtualAddress = UserSpaceLayout.mmapMin

    /// The highest page boundary a 64-bit address can name.
    private static let topPage: VirtualAddress = UInt64.max & ~(page - 1)


    // MARK: - Arithmetic

    @Test("a request that would end past 2^64 is refused, not wrapped")
    func upwardEndPastTopIsRefused() {
        var list = VMAList(minAddress: UInt64.max - 0x17FF, maxAddress: UInt64.max)

        // The window holds 0x17FF bytes, but aligned up it holds only 0xFFF.
        #expect(list.findFreeGAP(size: Self.page, alignment: Self.page) == nil)
        #expect(list.findFreeGAP(size: 0xFFF, alignment: Self.page) == Self.topPage)
    }


    @Test("a fit that would end past 2^64 behind a region is refused")
    func upwardEndPastTopBehindRegionIsRefused() {
        withList(
            regions: [(Self.topPage - 2 * Self.page, Self.topPage - Self.page)],
            window : (Self.topPage - 2 * Self.page - 0x800, UInt64.max)
        ) { fixture in
            // The last hole is [topPage - page, 2^64 - 1): one page fits, two
            // would need an end the address space does not have.
            #expect(fixture.list.findFreeGAP(size: 2 * Self.page, alignment: Self.page) == nil)
            #expect(fixture.list.findFreeGAP(size: Self.page, alignment: Self.page) == Self.topPage - Self.page)
        }
    }


    @Test("rounding an address up past 2^64 is refused, not wrapped to zero")
    func alignmentPastTopIsRefused() {
        var list = VMAList(minAddress: UInt64.max - 0x7FF, maxAddress: UInt64.max)

        #expect(list.findFreeGAP(size: 0x100, alignment: Self.page) == nil)
        #expect(list.findFreeGAP(size: 0x100, alignment: 0x100) == UInt64.max - 0x7FF)
    }


    @Test("an alignment that is zero or not a power of two is refused")
    func invalidAlignmentIsRefused() {
        var list = VMAList(minAddress: Self.base, maxAddress: Self.base + 16 * Self.page)

        for alignment: UInt64 in [0, 3, 0x1800, UInt64.max] {
            for direction in [GapDirection.upward, .downward] {
                #expect(list.findFreeGAPInRange(
                    min      : Self.base,
                    max      : Self.base + 16 * Self.page,
                    size     : Self.page,
                    alignment: alignment,
                    direction: direction
                ) == nil, "alignment \(alignment) \(direction)")
            }
        }

        // The largest power of two is still a mask, and the window's own base
        // is the only address it allows.
        let top = UInt64(1) << 63
        #expect(list.findFreeGAPInRange(
            min: top, max: top + Self.page, size: Self.page, alignment: top, direction: .upward
        ) == top)
    }


    // MARK: - Reference

    @Test("random placements and unmaps always agree with a brute-force search")
    func randomHistoryMatchesReference() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: UInt64) -> UInt64 {
            // SplitMix64: deterministic, so a failure replays exactly.
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return (z ^ (z >> 31)) % bound
        }

        withList(regions: []) { fixture in
            for step in 0..<3000 {
                let size = (1 + next(6)) * Self.page

                switch next(10) {
                    case 0...5:
                        let expected = fixture.reference(min: Self.base, max: Self.ceiling, size: size)
                        let found    = fixture.find(size: size)
                        #expect(found == expected, "step \(step)")
                        if let found, fixture.list.admitsNode { fixture.place(at: found, size: size) }

                    case 6...8:
                        guard fixture.list.nodeCount > 0 else { continue }
                        let victim = fixture.nth(Int(next(UInt64(fixture.list.nodeCount))))
                        fixture.list.remove(element: victim)

                    default:
                        // A lower ceiling, as brk and mmap search different windows.
                        let ceiling = Self.ceiling - next(64) * Self.page
                        let found = fixture.list.findFreeGAPInRange(
                            min: Self.base, max: ceiling, size: size,
                            alignment: Self.page, direction: .downward
                        )
                        #expect(found == fixture.reference(min: Self.base, max: ceiling, size: size),
                                "step \(step)")
                }
            }
        }
    }


    // MARK: - Fixture

    /// Top of the window the reference test searches, 64 pages above `base`.
    private static let ceiling: VirtualAddress = base + 64 * page


    /// A list over the test window plus every node ever made for it.
    private struct Fixture {
        var list : VMAList
        var nodes: [UnsafeMutablePointer<VirtualMemoryArea>] = []


        /// The downward search `mmapAnonymous` runs, over the test window.
        mutating func find(size: UInt64) -> VirtualAddress? {
            list.findFreeGAPInRange(
                min      : VMAListGapTests.base,
                max      : VMAListGapTests.ceiling,
                size     : size,
                alignment: VMAListGapTests.page,
                direction: .downward
            )
        }


        /// Search, then link a region where the search said, as an mmap does.
        mutating func place(size: UInt64) {
            guard let start = find(size: size) else {
                Issue.record("no room for \(size) bytes")
                return
            }
            place(at: start, size: size)
        }


        mutating func place(at start: VirtualAddress, size: UInt64) {
            let node = makeNode(start, start + size)
            #expect(refusal { try list.insert(node) } == "none")
        }


        mutating func makeNode(
            _ start: VirtualAddress,
            _ end  : VirtualAddress
        ) -> UnsafeMutablePointer<VirtualMemoryArea> {
            let node = UnsafeMutablePointer<VirtualMemoryArea>.allocate(capacity: 1)
            node.initialize(to: VirtualMemoryArea(
                startAddress: start,
                endAddress  : end,
                permissions : [.read, .write, .user],
                backingType : .anonymous,
                mappingFlags: .none,
                memoryType  : .normal
            ))
            nodes.append(node)

            return node
        }


        func node(at address: VirtualAddress) -> UnsafeMutablePointer<VirtualMemoryArea> {
            list.search(at: address)!
        }


        func nth(_ index: Int) -> UnsafeMutablePointer<VirtualMemoryArea> {
            var current = list.head!
            for _ in 0..<index { current = current.pointee.next! }
            return current
        }


        mutating func expectMatchesReference(
            size          : UInt64,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let expected = reference(min: VMAListGapTests.base, max: VMAListGapTests.ceiling, size: size)
            #expect(find(size: size) == expected, sourceLocation: sourceLocation)
        }


        /// The highest page-aligned fit in `[min, max)`, from the chain alone.
        func reference(
            min : VirtualAddress,
            max : VirtualAddress,
            size: UInt64
        ) -> VirtualAddress? {
            let page = VMAListGapTests.page
            var taken: [(VirtualAddress, VirtualAddress)] = []
            var current = list.head
            while let node = current {
                taken.append((node.pointee.startAddress, node.pointee.endAddress))
                current = node.pointee.next
            }

            guard max >= size else { return nil }
            var candidate = (max - size) & ~(page - 1)
            while candidate >= min {
                if !taken.contains(where: { $0.0 < candidate + size && candidate < $0.1 }) {
                    return candidate
                }
                guard candidate >= page else { return nil }
                candidate -= page
            }

            return nil
        }
    }


    private func withList(
        regions: [(start: VirtualAddress, end: VirtualAddress)],
        window : (min: VirtualAddress, max: VirtualAddress) = (base, ceiling),
        _ body : (inout Fixture) -> Void
    ) {
        var fixture = Fixture(list: VMAList(minAddress: window.min, maxAddress: window.max))
        for region in regions {
            let node = fixture.makeNode(region.start, region.end)
            #expect(refusal { try fixture.list.insert(node) } == "none")
        }

        body(&fixture)

        for node in fixture.nodes {
            node.deinitialize(count: 1)
            node.deallocate()
        }
    }
}
