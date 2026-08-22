//
//  VMADecommitTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// `VMAManager.decommit`'s validation pass, which is the other half of the
/// retirement contract: the range is refused outright unless every region it
/// covers is backed by frames this address space may free.
///
/// The pass runs before anything is retired, so the fixture needs no resident
/// pages. The page tables are left empty on purpose: the anonymous control then
/// walks a range with nothing mapped, which is the shape of a reservation nobody
/// touched, and reaches `.completed` in a single step.
///
/// The manager's frame metadata is unhooked deliberately, see the comment in
/// `withManager`.
///
/// The accepted range reaches `driveRetirement`, so this suite advances
/// `PageRetirement.retiredPages`, the same global counter `PageRetirementTests`
/// takes deltas of, and the preemption span table the driver merges into. Nothing
/// here asserts on either, and both readers work in deltas, but the run needs
/// `swift test --no-parallel` all the same (see the `test` target in the Makefile).
@Suite("VMA decommit")
struct VMADecommitTests {

    private static let pageSize: UInt64 = 4096
    private static let base    : VirtualAddress = UserSpaceLayout.elfBaseTypical


    @Test("a file-backed range is refused rather than freed")
    func refusesFileBacked() {
        withManager { ram, manager in
            register(manager, from: 0, pages: 4, backing: .fileBacked)

            // A decommit promises the pages are gone and the next touch faults back
            // in zeroed, which initrd frames cannot honour, so it is refused instead.
            #expect(refusal {
                _ = try manager.pointee.decommit(
                    addr: Self.base,
                    size: 4 * Self.pageSize
                )
            } == "unownedBacking")

            // Pass A refuses before pass B runs, so the region is still registered
            // and the resident count has not moved.
            #expect(manager.pointee.residentPages == 0)
            #expect(registeredStarts(manager) == [Self.base])
        }
    }


    @Test("shared and device ranges are refused for the same reason")
    func refusesOtherBackings() {
        for backing in [BackingType.shared, .device] {
            withManager { ram, manager in
                register(manager, from: 0, pages: 2, backing: backing)

                #expect(refusal {
                    _ = try manager.pointee.decommit(
                        addr: Self.base,
                        size: 2 * Self.pageSize
                    )
                } == "unownedBacking")
            }
        }
    }


    @Test("one unowned region in the range refuses the whole request")
    func refusesWholeRangeForOneRegion() {
        withManager { ram, manager in
            register(manager, from: 0, pages: 2, backing: .anonymous)
            register(manager, from: 2, pages: 2, backing: .fileBacked)

            // The range starts in a region this address space does own. A partial
            // decommit would report success with pages resident and not say which.
            #expect(refusal {
                _ = try manager.pointee.decommit(
                    addr: Self.base,
                    size: 4 * Self.pageSize
                )
            } == "unownedBacking")

            #expect(registeredStarts(manager) == [Self.base, Self.base + 2 * Self.pageSize])
        }
    }


    @Test("an anonymous range is accepted and runs to completion")
    func acceptsAnonymous() {
        withManager { ram, manager in
            register(manager, from: 0, pages: 4, backing: .anonymous)

            var completed = false
            do {
                if case .completed = try manager.pointee.decommit(
                    addr: Self.base,
                    size: 4 * Self.pageSize
                ) { completed = true }

            } catch { Issue.record("decommit refused an anonymous range: \(error)") }

            // Four pages is one batch, so the operation finishes in a single step and
            // the driver never reaches a checkpoint.
            #expect(completed)

            // The region stays registered: leaving every VMA in place is the whole
            // difference between decommitting a range and unmapping it.
            #expect(registeredStarts(manager) == [Self.base])
        }
    }


    @Test("a range that is unaligned, empty or unmapped is refused as a layout error")
    func refusesInvalidRanges() {
        withManager { ram, manager in
            register(manager, from: 0, pages: 2, backing: .anonymous)

            #expect(refusal {
                _ = try manager.pointee.decommit(addr: Self.base + 8, size: Self.pageSize)
            } == "invalidLayout")

            #expect(refusal {
                _ = try manager.pointee.decommit(addr: Self.base, size: 0)
            } == "invalidLayout")

            // No region overlaps this range at all, which is a different refusal from
            // a region whose frames are not ours.
            #expect(refusal {
                _ = try manager.pointee.decommit(
                    addr: Self.base + 64 * Self.pageSize,
                    size: Self.pageSize
                )
            } == "invalidLayout")
        }
    }


    // MARK: - Fixture

    /// Stands up a `VMAManager` over a host arena and runs `body` on it.
    ///
    /// The manager's frame metadata is set to `nil` before the heap is built, which
    /// is what keeps this fixture safe: the staged manager's allocator is zeroed and
    /// unreachable, so an `alloc` reaching it would follow a null free-list pointer,
    /// while with no metadata `alloc` refuses first and the refusal travels the
    /// kernel's own error path. Nothing below needs an allocation to succeed.
    private func withManager(
        _ body: (HostRAM, UnsafeMutablePointer<VMAManager>) -> Void
    ) {
        withHostRAM(pages: 16) { ram in
            ram.ppm.pointee.framesMetadata = nil

            let heap = UnsafeMutablePointer<BucketsHeap>.allocate(capacity: 1)
            heap.initialize(to: BucketsHeap(ppmPtr: ram.ppm))

            let manager = UnsafeMutablePointer<VMAManager>.allocate(capacity: 1)
            manager.initialize(to: VMAManager(
                heap             : heap,
                vmm              : ram.vmm,
                ppm              : ram.ppm,
                rootTablePhysical: ram.rootTablePhysical
            ))

            body(ram, manager)

            for node in registeredNodes(manager) {
                node.deinitialize(count: 1)
                node.deallocate()
            }

            manager.deinitialize(count: 1)
            manager.deallocate()
            heap.deinitialize(count: 1)
            heap.deallocate()
        }
    }


    /// Links a region straight into the manager's list.
    ///
    /// `registerRegion` is the real entry point and it needs a working kernel heap
    /// for the node, which a host process cannot give it. The list is the only state
    /// the validation pass reads, so the node is allocated here and inserted.
    private func register(
        _ manager: UnsafeMutablePointer<VMAManager>,
        from  firstPage: UInt64,
        pages          : UInt64,
        backing        : BackingType
    ) {
        let node = UnsafeMutablePointer<VirtualMemoryArea>.allocate(capacity: 1)
        node.initialize(to: VirtualMemoryArea(
            startAddress: Self.base + firstPage * Self.pageSize,
            endAddress  : Self.base + (firstPage + pages) * Self.pageSize,
            permissions : [.read, .write, .user],
            backingType : backing,
            mappingFlags: .none
        ))

        manager.pointee.vmaList.insert(node)
    }


    private func registeredNodes(
        _ manager: UnsafeMutablePointer<VMAManager>
    ) -> [UnsafeMutablePointer<VirtualMemoryArea>] {
        var result : [UnsafeMutablePointer<VirtualMemoryArea>] = []
        var current = manager.pointee.vmaList.head

        while let node = current {
            result.append(node)
            current = node.pointee.next
        }

        return result
    }


    private func registeredStarts(
        _ manager: UnsafeMutablePointer<VMAManager>
    ) -> [VirtualAddress] {
        registeredNodes(manager).map { $0.pointee.startAddress }
    }
}
