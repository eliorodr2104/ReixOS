//
//  RetirementWalk.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// The clamped forward walk over the VMAs of a range, shared by the two
/// retirement operations.
///
/// Both are handed an entry point into the sorted list, both have to clip the
/// first and last node of the walk to the user's range, and both hand one batch
/// at a time to `PageRetirement`. What they do to a node whose pages are all
/// retired is the only difference left, which is why this is a value they hold
/// rather than a type they specialize.
struct RetirementWalk {

    private let rangeStart: VirtualAddress
    private let rangeEnd  : VirtualAddress

    /// The VMA the next batch comes from, `nil` once the walk is over.
    private(set) var node: UnsafeMutablePointer<VirtualMemoryArea>?

    /// First address of `node` that has not been retired yet.
    private var cursor: VirtualAddress


    /// - Parameter first: any VMA overlapping the range, the caller's own entry
    ///   point into the sorted list. The walk goes forward from it.
    init(
        from first: UnsafeMutablePointer<VirtualMemoryArea>,
        start     : VirtualAddress,
        end       : VirtualAddress
    ) {
        self.rangeStart = start
        self.rangeEnd   = end
        self.node       = first
        self.cursor     = start

        guard let clamped = Self.clamp(
            first,
            start: start,
            end  : end
        ) else {
            advance(from: first.pointee.next)
            return
        }

        self.cursor = clamped.start
    }


    var isFinished: Bool { node == nil }


    /// The node and the range the next batch retires, `nil` once the walk is
    /// over. `finishesNode` is `true` when the batch reaches the end of what
    /// this node has inside the range.
    func nextBatch() -> (
        node        : UnsafeMutablePointer<VirtualMemoryArea>,
        start       : VirtualAddress,
        end         : VirtualAddress,
        finishesNode: Bool
    )? {
        guard let nodePtr = node,
              let clamped = Self.clamp(
                  nodePtr,
                  start: rangeStart,
                  end  : rangeEnd
              )
        else { return nil }

        let batchEnd = PageRetirement.batchEnd(
            from : cursor,
            limit: clamped.end
        )

        return (nodePtr, cursor, batchEnd, batchEnd >= clamped.end)
    }


    /// Move the cursor past a batch that has been retired.
    mutating func consume(through end: VirtualAddress) {
        cursor = end
    }


    /// Move to the next VMA with anything left inside the range.
    ///
    /// The successor is a parameter and not read off `node`, because a caller
    /// that frees the node it just finished has to read it while the node is
    /// still allocated. The list is sorted by start address, so a node starting
    /// at or past the range's end ends the walk rather than being skipped over.
    mutating func advance(
        from successor: UnsafeMutablePointer<VirtualMemoryArea>?
    ) {
        var probe = successor

        node = nil

        while let nodePtr = probe, nodePtr.pointee.startAddress < rangeEnd {

            if let clamped = Self.clamp(
                nodePtr,
                start: rangeStart,
                end  : rangeEnd
            ) {
                node   = nodePtr
                cursor = clamped.start
                return
            }

            probe = nodePtr.pointee.next
        }
    }


    /// The part of `nodePtr` that lies inside `[start, end)`, `nil` when none of
    /// it does.
    private static func clamp(
        _ nodePtr: UnsafeMutablePointer<VirtualMemoryArea>,
        start    : VirtualAddress,
        end      : VirtualAddress
    ) -> (start: VirtualAddress, end: VirtualAddress)? {

        let vma     = nodePtr.pointee
        let clamped = (
            start: vma.startAddress < start ? start : vma.startAddress,
            end  : vma.endAddress   > end   ? end   : vma.endAddress
        )

        guard clamped.start < clamped.end else { return nil }

        return clamped
    }
}
