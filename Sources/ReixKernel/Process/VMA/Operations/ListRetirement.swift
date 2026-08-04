//
//  ListRetirement.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// `VMAManager.teardown`, cut into steps so the interrupt window has somewhere
/// to open inside it.
///
/// One step is one batch, see `PageRetirement.pagesPerBatch`, and the step that
/// finishes a region also frees its node, because the node is what says where
/// the region ended.
///
/// It owns the chain it walks: `teardown` moves the whole VMA list out of the
/// manager and keeps an empty one, so this is free to pop nodes and free them,
/// which `RangeRetirement` deliberately is not. A step pops the region it is
/// about to work on, so a node leaves the chain before any of its pages are
/// retired.
///
/// A step that empties a region returns `.more` without looking at what is left,
/// so the run ends on a step that finds the chain empty and retires nothing. That
/// is one wasted step per teardown, against asking `LinkedList.count` whether the
/// chain is empty and leaking every remaining region if that count ever drifted.
struct ListRetirement: ResumableOperation {

    typealias Failure = Never

    private let heap   : UnsafeMutablePointer<BucketsHeap>
    private let context: PagingContext

    /// The regions still to retire, no longer reachable from the manager.
    private var nodes: LinkedList<VirtualMemoryArea>

    /// The region being retired, already off `nodes`, `nil` between two of them
    /// and before the first.
    private var node: UnsafeMutablePointer<VirtualMemoryArea>?

    /// First address of `node` that has not been retired yet.
    private var cursor: VirtualAddress


    /// - Parameter nodes: the manager's whole VMA chain, which the caller has
    ///   already stopped pointing at.
    init(
        heap   : UnsafeMutablePointer<BucketsHeap>,
        context: PagingContext,
        nodes  : LinkedList<VirtualMemoryArea>
    ) {
        self.heap    = heap
        self.context = context
        self.nodes   = nodes
        self.node    = nil
        self.cursor  = 0
    }


    mutating func step() -> Progress {

        let nodePtr: UnsafeMutablePointer<VirtualMemoryArea>

        if let current = node {
            nodePtr = current

        } else {
            guard let popped = nodes.popFront() else { return .done }

            node    = popped
            cursor  = popped.pointee.startAddress
            nodePtr = popped
        }

        let end     = nodePtr.pointee.endAddress
        let backing = nodePtr.pointee.backingType

        let batchEnd = PageRetirement.batchEnd(
            from : cursor,
            limit: end
        )

        PageRetirement.retire(
            context: context,
            start  : cursor,
            end    : batchEnd,
            backing: backing
        )

        cursor = batchEnd

        guard cursor >= end else { return .more }

        heap.pointee.kfree(nodePtr)
        node = nil

        return .more
    }
}
