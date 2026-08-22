//
//  VMAManager+Decommit.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

extension VMAManager {

    /// What a `decommit` call achieved, given that not finishing is not a failure.
    ///
    /// Reported as a value and not thrown, because `DecommitSyscall` maps every
    /// `VMAError` to `UInt64.max` and a suspension is the opposite of an error: the
    /// request was valid, part of it has already been performed, and the caller is
    /// being told to come back rather than being refused.
    public enum DecommitOutcome {

        /// Every page in the range is retired.
        case completed

        /// A checkpoint gave the CPU up. The rest of the range is parked on this
        /// manager, and the syscall has to be re-executed to finish it.
        case restartSyscall
    }


    /// A `decommit` stopped mid-retirement, with the range that identifies it.
    ///
    /// The range is recorded and compared on the way back so a stale continuation
    /// is a mismatch and not an argument: it is thrown away and the request
    /// validated from scratch. `DecommitSyscall` rewinds `ELR_EL1` onto the `svc`,
    /// so the next call from that process should be the same one, and this closes
    /// the class rather than reasoning it shut across four files.
    struct SuspendedDecommit {
        let operation: RangeRetirement
        let start    : VirtualAddress
        let end      : VirtualAddress
    }


    /// Release the frames behind `[addr, addr + size)` while leaving every VMA it
    /// covers registered, so a lazily backed page faults back in zeroed.
    ///
    /// Two passes, and the split is what makes the second one infallible: pass A
    /// refuses the whole request unless every overlapped region is this address
    /// space's to free, pass B then retires the pages and cannot fail. Pass B is
    /// driven by `Preemption`, because the range is a user's argument and can be as
    /// large as the mmap window.
    public mutating func decommit(
        addr: VirtualAddress,
        size: UInt64
    ) throws(VMAError) -> DecommitOutcome {

        // Taken whether this call turns out to match it or not, so no entry can
        // leave a stale one behind for a later one to find.
        let parked = suspendedDecommit
        suspendedDecommit = nil

        guard let range = Self.validatedRange(
            addr: addr,
            size: size
        ) else { throw .invalidLayout }

        if let parked, parked.start == range.start, parked.end == range.end {
            return driveRetirement(parked.operation, over: range)
        }

        // MARK: Pass A, validation only: nothing is retired unless all of it can be.

        let overlapping = try ownedRegions(over: range)

        // MARK: Pass B: retire the pages, one batch per step.

        return driveRetirement(
            RangeRetirement(
                context: context,
                from   : overlapping,
                start  : range.start,
                end    : range.end
            ),
            over: range
        )
    }


    /// The lowest VMA overlapping `range`, refusing the request unless every
    /// region the range covers is backed by frames this address space may free.
    ///
    /// `.anonymous` is the only backing that qualifies, and the refusal is the
    /// whole point of the pass rather than a missing feature. A decommit promises
    /// the frames are gone and the next touch faults back in a zeroed page, and
    /// none of the other backings can keep that promise: `.fileBacked` maps
    /// permanently resident initrd frames owned by a reserved range, `.shared`
    /// frames belong to a `SharedRegion` other address spaces still hold, and
    /// `.device` frames are not RAM. See `BackingType.fileBacked`.
    ///
    /// Refusing the whole request rather than skipping the offending regions keeps
    /// the syscall's report honest: a partial decommit would return success while
    /// leaving pages resident, and the caller has no way to learn which. Retiring
    /// such a region is unmap-only work `munmap` does, not this.
    private func ownedRegions(
        over range: (start: VirtualAddress, end: VirtualAddress)
    ) throws(VMAError) -> UnsafeMutablePointer<VirtualMemoryArea> {

        guard let overlapping = vmaList.searchOverlap(
            start: range.start,
            end  : range.end
        ) else { throw .invalidLayout }

        var probe: UnsafeMutablePointer<VirtualMemoryArea>? = overlapping
        while let nodePtr = probe, nodePtr.pointee.startAddress < range.end {

            guard nodePtr.pointee.backingType == .anonymous else {
                throw .unownedBacking
            }

            probe = nodePtr.pointee.next
        }

        return overlapping
    }


    /// Step `operation` to the end of its range, parking it if a checkpoint gives
    /// the CPU up first.
    ///
    /// Shared by the fresh and the resumed path so that one place decides what a
    /// suspension means, and so the range recorded with a park is always the range
    /// the operation was built for.
    ///
    /// The resident count is settled by the delta `PageRetirement` accumulated
    /// across this entry, so a suspended run charges the pages it did retire and
    /// the entry that finishes the range charges the rest. See
    /// `PageRetirement.retiredPages` for why the operation cannot carry it.
    private mutating func driveRetirement(
        _ operation: consuming RangeRetirement,
        over range : (start: VirtualAddress, end: VirtualAddress)
    ) -> DecommitOutcome {

        let before = PageRetirement.retiredPages

        defer { noteRetired(UInt32(truncatingIfNeeded: PageRetirement.retiredPages &- before)) }

        switch Preemption.run(RegionDecommit.self, operation) {

            case .completed: return .completed

            case .suspended(let remaining):
                suspendedDecommit = SuspendedDecommit(
                    operation: remaining,
                    start    : range.start,
                    end      : range.end
                )

                return .restartSyscall
        }
    }
}
