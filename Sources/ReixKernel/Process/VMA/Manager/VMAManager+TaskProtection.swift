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
                    virtual  : cursor,
                    flags    : permissions.toPageFlags()
                )
                Arch.MMU.flushTLBPage(cursor)

            } catch {
                var rollback = start
                while rollback < cursor {
                    try? context.vmm.pointee.protectUserPage(
                        rootTable: context.rootTablePhysical,
                        virtual  : rollback,
                        flags    : previous.toPageFlags()
                    )
                    Arch.MMU.flushTLBPage(rollback)
                    rollback += UserSpaceLayout.pageSize
                }
                return false
            }

            cursor += UserSpaceLayout.pageSize
        }

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
