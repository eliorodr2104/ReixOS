//
//  UnmapRetirement.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Phase 3 of `VMAManager.munmapRegion`, cut into steps so the interrupt window
/// has somewhere to open inside it.
///
/// The whole of phase 3, which is what makes `RegionUnmap` `.rescheduling`: the
/// page work *and* the unregistration of every node the range covered. With the
/// unlink and the `kfree` in a loop after `Preemption.run`, a suspension would
/// skip them and leave an address space describing regions whose pages are gone.
///
/// ## What a step boundary leaves
///
/// A node is freed only when every page of it inside the range has been retired,
/// and in the same step, so between two steps the list holds every node with
/// pages left and holds no freed node. A node still linked over pages already
/// retired is observed by nobody: this process executes no instruction and takes
/// no fault until the syscall returns or is re-entered, nothing an interrupt
/// handler touches reads a user VMA, and no other process can reach this address
/// space. That is also what keeps a process killed mid-unmap from leaking:
/// `teardown` walks the same list and finishes the nodes this never reached.
///
/// Nodes are freed whole, which phase 2 guarantees by splitting at both ends
/// first: every node the walk reaches lies inside the range, so the clamp only
/// ever trims a node this operation is not going to free.
struct UnmapRetirement: ResumableOperation {

    typealias Failure = Never

    /// Where the VMA list, the brk cache and the kernel heap are. See
    /// `VMAManager.managerPointer` for why the operation that has to unregister
    /// what it retires holds the manager, and `RangeRetirement` for why the one
    /// that only retires pages deliberately holds none of it.
    private var manager: UnsafeMutablePointer<VMAManager>

    private let context: PagingContext

    private var walk: RetirementWalk


    /// - Parameter first: the lowest VMA overlapping the range, the caller's own
    ///   entry point into the sorted list. The walk goes forward from it.
    init(
        manager   : UnsafeMutablePointer<VMAManager>,
        context   : PagingContext,
        from first: UnsafeMutablePointer<VirtualMemoryArea>,
        start     : VirtualAddress,
        end       : VirtualAddress
    ) {
        self.manager = manager
        self.context = context
        self.walk    = RetirementWalk(
            from : first,
            start: start,
            end  : end
        )
    }


    /// Point the operation at the manager again, done at the start of every run.
    ///
    /// The pointer cannot have changed, since a `VMAManager` is `kmalloc`ed once
    /// and never moves, and that is exactly what this makes irrelevant: a
    /// continuation parked across a suspension is rebound by the entry that
    /// resumes it, so it never runs on an address taken by an earlier one.
    mutating func rebind(to manager: UnsafeMutablePointer<VMAManager>) {
        self.manager = manager
    }


    mutating func step() -> Progress {
        guard let batch = walk.nextBatch() else { return .done }

        PageRetirement.retire(
            context: context,
            start  : batch.start,
            end    : batch.end,
            backing: batch.node.pointee.backingType
        )

        walk.consume(through: batch.end)

        guard batch.finishesNode else { return .more }

        // Read while the node is still linked and still allocated: `unregister`
        // frees it, and the heap threads its free list through `startAddress`.
        let successor = batch.node.pointee.next

        manager.pointee.unregister(batch.node)

        walk.advance(from: successor)

        return walk.isFinished ? .done : .more
    }
}
