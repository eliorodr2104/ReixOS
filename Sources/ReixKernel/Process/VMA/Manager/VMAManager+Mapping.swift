//
//  VMAManager+Mapping.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

extension VMAManager {

    /// Register a new VMA over `[start, start + size)` without touching the page
    /// tables. Used by the spawn path to declare ELF segments and the user stack
    /// region: the actual PTE mapping is done by the caller (eager) or deferred to
    /// the first page-fault (lazy).
    public mutating func registerRegion(
        start       : VirtualAddress,
        size        : UInt64,
        permissions : VMAPermissions,
        backing     : BackingType,
        flags       : MappingFlags,
        sharedRegion: UnsafeMutablePointer<SharedRegion>? = nil
    ) throws(VMAError) {
        guard size > 0 else { throw .invalidLayout }
        guard (backing == .shared) == (sharedRegion != nil) else { throw .invalidLayout }

        let end = start + size
        guard start >= UserSpaceLayout.userMin,
              end   <= UserSpaceLayout.userMax
        else { throw .invalidLayout }

        if vmaList.searchOverlap(start: start, end: end) != nil {
            throw .regionOverlap
        }

        guard let nodePtr = heap.pointee.kmallocOrNil(VirtualMemoryArea.self) else {
            throw .heapAllocationFailed(.allocationFailed(reason: .fullMemory))
        }

        nodePtr.initialize(
            to: VirtualMemoryArea(
                startAddress: start,
                endAddress  : end,
                permissions : permissions,
                backingType : backing,
                mappingFlags: flags,
                sharedRegion: sharedRegion
            )
        )

        if let sharedRegion { retainSharedRegion(sharedRegion) }

        vmaList.insert(nodePtr)

        var survivor = nodePtr
        if let prev = survivor.pointee.prev,
           let removed = vmaList.mergeAdjacent(prev, survivor) {
            if removed == brkVMA { brkVMA = prev }
            heap.pointee.kfree(removed)
            survivor = prev
        }
        if let next = survivor.pointee.next,
           let removed = vmaList.mergeAdjacent(survivor, next) {
            if removed == brkVMA { brkVMA = survivor }
            heap.pointee.kfree(removed)
        }
    }


    /// Place `pageCount` pages of `physicalBase` in the mmap area with exactly
    /// `permissions`.
    ///
    /// `permissions` is the caller's to choose because the two syscalls that reach
    /// here derive it from the capability being mapped, and a region capability
    /// that carries no `.write` has to produce a read-only window.
    public mutating func mapRegion(
        physicalBase: PhysicalAddress,
        pageCount   : Int,
        kind        : RegionKind,
        permissions : VMAPermissions,
        sharedRegion: UnsafeMutablePointer<SharedRegion>? = nil
    ) throws(VMAError) -> VirtualAddress {

        guard pageCount > 0 else { throw .invalidLayout }
        // Both region kinds that name an object have to bring one, and the one
        // that does not must not: a device window has no region to account to.
        guard (kind == .shared || kind == .dma) == (sharedRegion != nil) else {
            throw .invalidLayout
        }

        let alignedSize = UInt64(pageCount) * UserSpaceLayout.pageSize

        guard let start = vmaList.findFreeGAPInRange(
            min      : UserSpaceLayout.mmapMin,
            max      : UserSpaceLayout.mmapBase,
            size     : alignedSize,
            alignment: UserSpaceLayout.pageSize,
            direction: .downward
        ) else { throw .noFreeGap }

        try registerRegion(
            start      : start,
            size       : alignedSize,
            permissions: permissions,
            backing    : kind.backing,
            flags      : .none,
            sharedRegion: sharedRegion
        )

        for i in 0..<pageCount {
            let currentVirtualPage: UInt64 = UInt64(i) * UserSpaceLayout.pageSize

            do {
                try context.vmm.pointee.mapUserPage(
                    rootTable: context.rootTablePhysical,
                    virtual  : start        + currentVirtualPage,
                    physical : physicalBase + currentVirtualPage,
                    flags    : permissions.toPageFlags(),
                    type     : kind.memoryType
                )

            } catch {
                try? rollbackMapping(addr: start, size: alignedSize)
                throw .mappingFailed(error)
            }

            noteMapped(1)
        }

        return start
    }


    /// Reserve an anonymous region in the mmap area with `permissions`.
    ///
    /// The region is registered as `.noReserve`: physical pages are allocated only
    /// when the user actually touches them. The hint is ignored in this milestone,
    /// placement is always automatic, in the topmost free gap of
    /// `[mmapMin, mmapBase)`.
    public mutating func mmapAnonymous(
        size       : UInt64,
        permissions: VMAPermissions
    ) throws(VMAError) -> VirtualAddress {

        guard size > 0, size <= UserSpaceLayout.mmapBase - UserSpaceLayout.mmapMin else {
            throw .invalidLayout
        }

        let alignedSize = (size + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

        guard let start = vmaList.findFreeGAPInRange(
            min      : UserSpaceLayout.mmapMin,
            max      : UserSpaceLayout.mmapBase,
            size     : alignedSize,
            alignment: UserSpaceLayout.pageSize,
            direction: .downward
        ) else { throw .noFreeGap }

        try registerRegion(
            start      : start,
            size       : alignedSize,
            permissions: permissions,
            backing    : .anonymous,
            flags      : .noReserve
        )

        return start
    }


    /// Move the program break upward to `newBreak`, page-aligned.
    ///
    /// Returns the new break value on success. Shrinking is rejected silently by
    /// returning the current break (no-op). The brk heap is represented by a
    /// single VMA `.noReserve`: on the first call the VMA is registered, on
    /// subsequent calls its end address is moved forward in place. The pages are
    /// not allocated here, the page fault handler materialises them lazily.
    public mutating func extendBreak(
        to newBreak: VirtualAddress
    ) throws(VMAError) -> VirtualAddress {

        guard newBreak >= UserSpaceLayout.userMin,
              newBreak <= UserSpaceLayout.mmapMin - UserSpaceLayout.pageSize else { throw .invalidLayout }

        let aligned = (newBreak + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

        if aligned <= currentBreak {
            return currentBreak
        }

        if let existing = brkVMA {
            if vmaList.searchOverlap(
                start: existing.pointee.endAddress,
                end  : aligned
            ) != nil {
                throw .regionOverlap
            }

            let grown = VirtualMemoryArea(
                startAddress: existing.pointee.startAddress,
                endAddress  : aligned,
                permissions : existing.pointee.permissions,
                prev        : existing.pointee.prev,
                next        : existing.pointee.next,
                backingType : existing.pointee.backingType,
                mappingFlags: existing.pointee.mappingFlags
            )
            existing.pointee = grown

        } else {
            try registerRegion(
                start      : currentBreak,
                size       : aligned - currentBreak,
                permissions: [.read, .write, .user],
                backing    : .anonymous,
                flags      : .noReserve
            )
            brkVMA = vmaList.search(at: currentBreak)
        }

        currentBreak = aligned
        return currentBreak
    }
}
