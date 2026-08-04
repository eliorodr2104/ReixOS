//
//  VMAManager+Unmap.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

extension VMAManager {

    /// What a `munmapRegion` call achieved, given that not finishing is not a
    /// failure.
    ///
    /// The twin of `DecommitOutcome`, deliberately not the same type: one shared
    /// enum would tie either syscall's contract to the other's under a name
    /// describing neither.
    public enum UnmapOutcome {

        /// The range is unmapped and every VMA it covered is unregistered.
        case completed

        /// A checkpoint gave the CPU up. The rest of the range is parked on this
        /// manager, and the syscall has to be re-executed to finish it.
        case restartSyscall
    }


    /// A `munmapRegion` stopped inside, with the range that identifies it.
    ///
    /// The range is recorded and compared on the way back for the reason
    /// `SuspendedDecommit` records it: a mismatch drops the continuation and
    /// validates from scratch.
    struct SuspendedUnmap {
        let operation: UnmapRetirement
        let start    : VirtualAddress
        let end      : VirtualAddress
    }


    /// Drop the mapping of `[addr, addr + size)`, releasing owned frames and
    /// unregistering every VMA the range covers.
    ///
    /// Three phases, ordered so that everything which can fail happens before
    /// anything which cannot be undone. Phase 3 is driven by `Preemption`: a dense
    /// unmap over the mmap window is about 110,000 pages, and it used to run every
    /// one of them with interrupts masked.
    ///
    /// `RegionUnmap` is `.rescheduling`, so `.restartSyscall` obliges
    /// `MunmapSyscall` to re-execute the call rather than report anything to the
    /// user.
    public mutating func munmapRegion(
        addr: VirtualAddress,
        size: UInt64
    ) throws(VMAError) -> UnmapOutcome {

        try unmapRange(
            RegionUnmap.self,
            addr: addr,
            size: size
        )
    }


    /// Undo a mapping this address space has just made, from a path that is already
    /// unwinding and has nobody left to tell to come back.
    ///
    /// Same work as `munmapRegion` through a different region,
    /// `RegionUnmapRollback`, which is `.latencyOnly`. Both internal rollbacks,
    /// `mapRegion`'s own and `ShmCreate`'s, discard the result with `try?` on a
    /// failure path taken precisely when a physical allocation has just failed. A
    /// `.restartSyscall` would be discarded with it, the syscall would return its
    /// failure and never be re-entered, and the user would be left holding a live
    /// read/write window onto frames already returned to the buddy allocator.
    ///
    /// The region closes that in the compiler rather than in a comment:
    /// `Region.mode` is a `static let` of a concrete type, so this specialization
    /// has no reachable `.suspended` case and never writes a continuation into
    /// `suspendedUnmap`, which it only clears on entry as every other entry does.
    /// `Void`, because a caller that cannot act on an outcome should not be handed
    /// one.
    public mutating func rollbackMapping(
        addr: VirtualAddress,
        size: UInt64
    ) throws(VMAError) {

        _ = try unmapRange(
            RegionUnmapRollback.self,
            addr: addr,
            size: size
        )
    }


    /// The body both unmap entry points share, generic over the region so that the
    /// rollback is compiled without a level-2 branch at all.
    ///
    /// `Region` is threaded down to here because this function holds the park: the
    /// specialization that folds `.suspended` out of `Preemption.run` has to be the
    /// same one that would otherwise have written it. A mode passed by value would
    /// leave the store to `suspendedUnmap` standing on the rollback path behind a
    /// branch nothing proves is never taken.
    private mutating func unmapRange<Region: PreemptionRegion>(
        _ region: Region.Type,
        addr    : VirtualAddress,
        size    : UInt64
    ) throws(VMAError) -> UnmapOutcome {

        // Read and cleared, so no exit below can leave a stale one behind.
        let parked     = suspendedUnmap
        suspendedUnmap = nil

        // MARK: Phase 1, validation only: the list is left exactly as it was.

        guard let range = Self.validatedRange(
            addr: addr,
            size: size
        ) else { throw .invalidLayout }

        if let parked, parked.start == range.start, parked.end == range.end {
            var resumed = parked.operation

            resumed.rebind(to: managerPointer())

            return driveUnmap(region, resumed, over: range)
        }

        let overlapping = try unmappableRegions(over: range)

        // MARK: Phase 2, the only fallible mutations: at most two splits.

        let first = try splitEdges(
            from : overlapping,
            over : range
        )

        // MARK: Phase 3, infallible from here on: every node is wholly inside.

        let operation = UnmapRetirement(
            manager: managerPointer(),
            context: context,
            from   : first,
            start  : range.start,
            end    : range.end
        )

        return driveUnmap(region, operation, over: range)
    }


    /// The lowest VMA overlapping `range`, refusing a request that would take the
    /// brk region apart.
    ///
    /// The brk heap is one VMA the manager keeps a pointer to, so it may be
    /// unmapped whole or not at all: a partial unmap would split it and leave the
    /// cache pointing at a node that no longer describes the break.
    private func unmappableRegions(
        over range: (start: VirtualAddress, end: VirtualAddress)
    ) throws(VMAError) -> UnsafeMutablePointer<VirtualMemoryArea> {

        guard let overlapping = vmaList.searchOverlap(
            start: range.start,
            end  : range.end
        ) else { throw .invalidLayout }

        var probe: UnsafeMutablePointer<VirtualMemoryArea>? = overlapping
        while let nodePtr = probe, nodePtr.pointee.startAddress < range.end {

            if nodePtr == brkVMA {
                guard nodePtr.pointee.startAddress >= range.start,
                      nodePtr.pointee.endAddress   <= range.end
                else { throw .invalidLayout }
            }

            probe = nodePtr.pointee.next
        }

        return overlapping
    }


    /// Split the first and the last overlapped VMA at the range's edges, so every
    /// node left inside it can be freed whole, and answer the first of them.
    private mutating func splitEdges(
        from overlapping: UnsafeMutablePointer<VirtualMemoryArea>,
        over range      : (start: VirtualAddress, end: VirtualAddress)
    ) throws(VMAError) -> UnsafeMutablePointer<VirtualMemoryArea> {

        var first = overlapping
        if range.start > first.pointee.startAddress {

            first = try vmaList.split(
                first,
                at   : range.start,
                using: heap
            )
        }

        var last = first
        while let next = last.pointee.next,
              next.pointee.startAddress < range.end {
            last = next
        }

        if last.pointee.endAddress > range.end {

            _ = try vmaList.split(
                last,
                at   : range.end,
                using: heap
            )
        }

        return first
    }


    /// Step `operation` to the end of its range, parking it if a checkpoint gives
    /// the CPU up first.
    ///
    /// The twin of `driveRetirement`, for the same reason it exists: one place
    /// decides what a suspension means. It is generic over the region and
    /// `driveRetirement` is not, because `decommit` has one caller and one mode
    /// while the unmap has two of each.
    private mutating func driveUnmap<Region: PreemptionRegion>(
        _    region   : Region.Type,
        _    operation: consuming UnmapRetirement,
        over range    : (start: VirtualAddress, end: VirtualAddress)
    ) -> UnmapOutcome {

        switch Preemption.run(region, operation) {

            case .completed: return .completed

            case .suspended(let remaining):
                suspendedUnmap = SuspendedUnmap(
                    operation: remaining,
                    start    : range.start,
                    end      : range.end
                )

                return .restartSyscall
        }
    }
}
