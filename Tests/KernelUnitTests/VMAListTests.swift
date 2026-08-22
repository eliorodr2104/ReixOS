//
//  VMAListTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The VMA list of one address space: the ordering `insert` maintains, the window
/// the gap search is confined to, and the merge rule that decides when two regions
/// may become one.
///
/// The nodes are host allocations rather than kernel heap cells, which is all the
/// list needs: it is an intrusive chain and never allocates. `mergeAdjacent` hands
/// the absorbed node back for the caller to free, so nothing here leaks it.
///
/// No global state, so this suite is parallel safe on its own. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("VMA list")
struct VMAListTests {

    private static let pageSize: UInt64 = 4096
    private static let base    : VirtualAddress = UserSpaceLayout.elfBaseTypical


    @Test("two adjacent anonymous regions with matching attributes become one")
    func mergesAnonymousNeighbours() {
        withRegions([
            region(from: 0, pages: 1, backing: .anonymous),
            region(from: 1, pages: 1, backing: .anonymous),
        ]) { list, nodes in
            var list = list

            let absorbed = list.mergeAdjacent(nodes[0], nodes[1])

            // The absorbed node is returned unlinked, which is what tells the caller
            // it now owns it and has to free it.
            #expect(absorbed == nodes[1])
            #expect(nodes[0].pointee.startAddress == Self.base)
            #expect(nodes[0].pointee.endAddress   == Self.base + 2 * Self.pageSize)
            #expect(nodes[0].pointee.next == nil)
            #expect(list.head == nodes[0])
            #expect(list.tail == nodes[0])
        }
    }


    @Test("two adjacent file-backed regions are never merged")
    func refusesFileBackedNeighbours() {
        withRegions([
            region(from: 0, pages: 1, backing: .fileBacked),
            region(from: 1, pages: 1, backing: .fileBacked),
        ]) { list, nodes in
            var list = list

            // Adjacent, same permissions, same flags, same backing: the refusal is
            // the backing itself, since the two may sit on unrelated file offsets.
            #expect(list.mergeAdjacent(nodes[0], nodes[1]) == nil)

            // Nothing moved: both regions keep their own extent and stay linked.
            #expect(nodes[0].pointee.endAddress   == Self.base + Self.pageSize)
            #expect(nodes[1].pointee.startAddress == Self.base + Self.pageSize)
            #expect(nodes[0].pointee.next == nodes[1])
            #expect(list.tail == nodes[1])
        }
    }


    @Test("shared and device neighbours are refused for the same reason")
    func refusesOtherBackings() {
        for backing in [BackingType.shared, .device] {
            withRegions([
                region(from: 0, pages: 1, backing: backing),
                region(from: 1, pages: 1, backing: backing),
            ]) { list, nodes in
                var list = list

                #expect(list.mergeAdjacent(nodes[0], nodes[1]) == nil)
                #expect(nodes[0].pointee.next == nodes[1])
            }
        }
    }


    @Test("regions that differ in permissions, flags or backing are not merged")
    func refusesMismatchedAttributes() {
        withRegions([
            region(from: 0, pages: 1, backing: .anonymous, permissions: [.read, .user]),
            region(from: 1, pages: 1, backing: .anonymous, permissions: [.read, .write, .user]),
        ]) { list, nodes in
            var list = list
            #expect(list.mergeAdjacent(nodes[0], nodes[1]) == nil)
        }

        withRegions([
            region(from: 0, pages: 1, backing: .anonymous, flags: .none),
            region(from: 1, pages: 1, backing: .anonymous, flags: .noReserve),
        ]) { list, nodes in
            var list = list
            #expect(list.mergeAdjacent(nodes[0], nodes[1]) == nil)
        }

        withRegions([
            region(from: 0, pages: 1, backing: .anonymous),
            region(from: 1, pages: 1, backing: .fileBacked),
        ]) { list, nodes in
            var list = list
            #expect(list.mergeAdjacent(nodes[0], nodes[1]) == nil)
        }
    }


    @Test("a gap between the two regions, or the wrong order, refuses the merge")
    func refusesNonAdjacent() {
        withRegions([
            region(from: 0, pages: 1, backing: .anonymous),
            region(from: 2, pages: 1, backing: .anonymous),
        ]) { list, nodes in
            var list = list

            // Linked but not touching: merging would swallow an unmapped page.
            #expect(nodes[0].pointee.next == nodes[1])
            #expect(list.mergeAdjacent(nodes[0], nodes[1]) == nil)

            // Backwards, so `first.next` is not `second` at all. The link test is
            // what stops a caller from merging two regions that are not neighbours.
            #expect(list.mergeAdjacent(nodes[1], nodes[0]) == nil)
        }
    }


    @Test("insert keeps the chain ordered and refuses an overlap")
    func insertOrdering() {
        withRegions([
            region(from: 4, pages: 1, backing: .anonymous),
            region(from: 0, pages: 1, backing: .anonymous),
            region(from: 2, pages: 1, backing: .anonymous),
        ]) { list, nodes in
            // Inserted out of order by the fixture, read back ascending.
            #expect(starts(of: list) == [0, 2, 4].map { Self.base + $0 * Self.pageSize })

            var list = list
            let overlapping = makeRegion(
                start: Self.base + 3 * Self.pageSize,
                end  : Self.base + 5 * Self.pageSize
            )
            defer { destroyRegion(overlapping) }

            // A region straddling an existing one is dropped rather than linked,
            // which is the invariant every walker here depends on.
            list.insert(overlapping)
            #expect(starts(of: list) == [0, 2, 4].map { Self.base + $0 * Self.pageSize })
            #expect(list.search(at: Self.base + 3 * Self.pageSize) == nil)
            #expect(list.search(at: Self.base + 4 * Self.pageSize) == nodes[0])
        }
    }


    @Test("the gap search only ever hands out addresses inside the window")
    func gapSearchStaysInsideWindow() {
        let windowStart = Self.base
        let windowEnd   = Self.base + 8 * Self.pageSize

        withRegions(
            [
                region(from: 0, pages: 1, backing: .anonymous),
                region(from: 1, pages: 1, backing: .anonymous),
            ],
            window: (windowStart, windowEnd)
        ) { list, _ in
            // The first two pages are taken, so the gap starts where they end and
            // stays below the window's own ceiling.
            let gap = list.findFreeGAP(size: 2 * Self.pageSize, alignment: Self.pageSize)
            #expect(gap == windowStart + 2 * Self.pageSize)

            // A request the window cannot hold is refused rather than served above
            // it: the two bounds are why this is a type and not a bare linked list.
            #expect(list.findFreeGAP(size: 9 * Self.pageSize, alignment: Self.pageSize) == nil)
            #expect(list.findFreeGAP(size: 0, alignment: Self.pageSize) == nil)

            // The last request that still fits ends exactly on the ceiling.
            let last = list.findFreeGAP(size: 6 * Self.pageSize, alignment: Self.pageSize)
            #expect(last == windowStart + 2 * Self.pageSize)
            #expect(last! + 6 * Self.pageSize == windowEnd)
        }
    }


    // MARK: - Fixture

    /// One region of the fixture, in pages from `base`.
    private struct RegionSpec {
        let firstPage  : UInt64
        let pages      : UInt64
        let backing    : BackingType
        let permissions: VMAPermissions
        let flags      : MappingFlags
    }


    private func region(
        from firstPage: UInt64,
        pages         : UInt64,
        backing       : BackingType,
        permissions   : VMAPermissions = [.read, .write, .user],
        flags         : MappingFlags   = .none
    ) -> RegionSpec {
        RegionSpec(
            firstPage  : firstPage,
            pages      : pages,
            backing    : backing,
            permissions: permissions,
            flags      : flags
        )
    }


    /// Builds a list over host-allocated nodes, runs `body`, then frees them.
    ///
    /// The nodes are handed over as well as the list, because every assertion here
    /// is about which node the links point at.
    private func withRegions(
        _ specs: [RegionSpec],
        window : (min: VirtualAddress, max: VirtualAddress) = (UserSpaceLayout.userMin, UserSpaceLayout.userMax),
        _ body : (VMAList, [UnsafeMutablePointer<VirtualMemoryArea>]) -> Void
    ) {
        var list  = VMAList(minAddress: window.min, maxAddress: window.max)
        var nodes: [UnsafeMutablePointer<VirtualMemoryArea>] = []

        for spec in specs {
            let node = UnsafeMutablePointer<VirtualMemoryArea>.allocate(capacity: 1)
            node.initialize(to: VirtualMemoryArea(
                startAddress: Self.base + spec.firstPage * Self.pageSize,
                endAddress  : Self.base + (spec.firstPage + spec.pages) * Self.pageSize,
                permissions : spec.permissions,
                backingType : spec.backing,
                mappingFlags: spec.flags
            ))

            list.insert(node)
            nodes.append(node)
        }

        body(list, nodes)

        for node in nodes { destroyRegion(node) }
    }


    private func makeRegion(
        start: VirtualAddress,
        end  : VirtualAddress
    ) -> UnsafeMutablePointer<VirtualMemoryArea> {
        let node = UnsafeMutablePointer<VirtualMemoryArea>.allocate(capacity: 1)
        node.initialize(to: VirtualMemoryArea(
            startAddress: start,
            endAddress  : end,
            permissions : [.read, .write, .user],
            backingType : .anonymous,
            mappingFlags: .none
        ))

        return node
    }


    private func destroyRegion(_ node: UnsafeMutablePointer<VirtualMemoryArea>) {
        node.deinitialize(count: 1)
        node.deallocate()
    }


    private func starts(of list: VMAList) -> [VirtualAddress] {
        var result : [VirtualAddress] = []
        var current = list.head

        while let node = current {
            result.append(node.pointee.startAddress)
            current = node.pointee.next
        }

        return result
    }
}
