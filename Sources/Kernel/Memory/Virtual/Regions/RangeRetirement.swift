//
//  RangeRetirement.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Pass B of `VMAManager.decommit`, cut into steps so the interrupt window has
/// somewhere to open inside it.
///
/// One step is one batch, see `PageRetirement.pagesPerBatch`. It walks the VMAs
/// covering the range and retires the pages of each, clamped to the range, which
/// is the whole of the caller's page work and none of its bookkeeping: that is
/// what keeps a pause point away from a half-edited list.
///
/// The list is only ever read. Keeping every VMA registered while its pages go
/// is the entire difference between decommitting a range and unmapping it, so a
/// step that dropped a reservation would silently turn one syscall into the
/// other. `munmap` has `UnmapRetirement` for that.
struct RangeRetirement: ResumableOperation {

    typealias Failure = Never

    private let context: PagingContext

    private var walk: RetirementWalk


    /// - Parameter first: any VMA overlapping the range, the caller's own entry
    ///   point into the sorted list. The walk goes forward from it.
    init(
        context   : PagingContext,
        from first: UnsafeMutablePointer<VirtualMemoryArea>,
        start     : VirtualAddress,
        end       : VirtualAddress
    ) {
        self.context = context
        self.walk    = RetirementWalk(
            from : first,
            start: start,
            end  : end
        )
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

        walk.advance(from: batch.node.pointee.next)

        return walk.isFinished ? .done : .more
    }
}
