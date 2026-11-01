//
//  VMAManager+TaskProtection.swift
//  ReixOS
//

extension VMAManager {

    /// Irreversibly applies the final permissions to one task-construction VMA.
    ///
    /// The range must be the exact region originally mapped by `taskMap`; this
    /// keeps protection atomic without splitting VMA nodes on a privileged path.
    /// Every PTE is changed before the logical VMA permission is published. A
    /// hardware mapping refusal restores the pages already changed.
    ///
    /// One batch for the whole range: every descriptor is rewritten with its
    /// own `dsb ishst`, then `PageRetirement.invalidate` retires the old entries
    /// under this space's tag with a single `dsb ish` and `isb`. No page is left
    /// permitted by a stale TLB entry once this returns.
    ///
    /// `protectUserPage` refuses an absent descriptor, which this range cannot
    /// have: `taskMap` backs every page of it before the region can be protected.
    mutating func protectTaskRegion(
        start      : VirtualAddress,
        end        : VirtualAddress,
        permissions: VMAPermissions
    ) -> Bool {
        guard end > start,
              !permissions.contains([.write, .execute]),
              let region = vmaList.search(at: start),
              region.pointee.startAddress == start,
              region.pointee.endAddress == end,
              region.pointee.backingType == .anonymous
        else { return false }

        let previous = region.pointee.permissions
        var cursor   = start

        while cursor < end {
            do {
                try context.vmm.pointee.protectUserPage(
                    rootTable: context.rootTablePhysical,
                    asid     : context.asid,
                    virtual  : cursor,
                    flags    : permissions.toPageFlags(),
                    type     : region.pointee.memoryType,
                    batched  : true
                )

            } catch {
                var rollback = start
                while rollback < cursor {
                    try? context.vmm.pointee.protectUserPage(
                        rootTable: context.rootTablePhysical,
                        asid     : context.asid,
                        virtual  : rollback,
                        flags    : previous.toPageFlags(),
                        type     : region.pointee.memoryType,
                        batched  : true
                    )
                    rollback += UserSpaceLayout.pageSize
                }

                PageRetirement.invalidate(asid: context.asid, start: start, end: cursor)
                return false
            }

            cursor += UserSpaceLayout.pageSize
        }

        PageRetirement.invalidate(asid: context.asid, start: start, end: end)

        region.pointee.permissions = permissions
        return true
    }

    /// Commit the sealed writable region ending at `top` as the task's stack.
    ///
    /// `taskSetContext` is the only operation that gives one mapped region stack
    /// semantics. Until then it is an inert construction VMA; afterwards a
    /// fault may extend it downward as far as the global stack limit.
    mutating func commitTaskStack(top: VirtualAddress) -> Bool {
        guard top > UserSpaceLayout.stackLimit,
              let region = vmaList.search(at: top - 1),
              region.pointee.endAddress == top,
              region.pointee.startAddress >= UserSpaceLayout.stackLimit,
              region.pointee.backingType == .anonymous,
              region.pointee.permissions.contains([.read, .write]),
              !region.pointee.permissions.contains(.execute),
              region.pointee.mappingFlags.contains(.taskConstruction)
        else { return false }

        region.pointee.mappingFlags = .growDown
        return true
    }
}
