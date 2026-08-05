//
//  VMAManager+Faults.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

import ReixABI

extension VMAManager {

    /// Decide what to do with a synchronous abort raised at `address`.
    ///
    /// Returns `true` if the manager fulfilled the access (lazy allocation, stack
    /// growth) and the user instruction can be restarted, `false` if the fault is
    /// a real segfault.
    public mutating func handlePageFault(
        at address: VirtualAddress,
        cause     : FaultCause
    ) -> Bool {

        guard address >= UserSpaceLayout.userMin,
              address <  UserSpaceLayout.userMax
        else { return false }

        if let vmaPtr = vmaList.search(at: address) {
            return serviceFault(
                vmaPtr : vmaPtr,
                address: address,
                cause  : cause
            )
        }

        if let growable = findGrowableStackVMA(below: address) {
            return tryGrowStack(
                vmaPtr: growable,
                downTo: address
            )
        }

        return false
    }


    /// Route a fault that landed inside a registered region to whatever can still
    /// fulfil it.
    private mutating func serviceFault(
        vmaPtr : UnsafeMutablePointer<VirtualMemoryArea>,
        address: VirtualAddress,
        cause  : FaultCause
    ) -> Bool {
        let vma = vmaPtr.pointee

        switch cause {
            case .translation:
                guard vma.mappingFlags.contains(.noReserve)
                   || vma.mappingFlags.contains(.growDown)
                else { return false }

                return materialize(
                    vma    : vma,
                    address: address
                )

            case .permission:
                return serviceCopyOnWrite(
                    vma    : vma,
                    address: address
                )

            case .alignment, .access: return false
        }
    }


    /// Take the write fault of a copy-on-write page.
    ///
    /// A frame nobody else holds needs no copy at all: the region is writable and
    /// only the descriptor is still read-only, so the permission is restored in
    /// place. That is also the path a parent lands on after its child is gone.
    private mutating func serviceCopyOnWrite(
        vma    : VirtualMemoryArea,
        address: VirtualAddress
    ) -> Bool {

        guard vma.mappingFlags.contains(.copyOnWrite),
              vma.permissions.contains(.write)
        else { return false }

        let aligned = address & ~(UserSpaceLayout.pageSize - 1)

        guard let phys = context.vmm.pointee.physicalAddressOf(
            rootTable: context.rootTablePhysical,
            virtual  : aligned
        ) else { return false }

        let flags = vma.permissions.toPageFlags()

        if context.ppm.pointee.refCount(of: phys) == 1 {

            do {
                try context.vmm.pointee.protectUserPage(
                    rootTable: context.rootTablePhysical,
                    virtual  : aligned,
                    flags    : flags
                )

            } catch { return false }

        } else {

            guard copyPage(
                from : phys,
                onto : aligned,
                flags: flags
            ) else { return false }
        }

        Arch.MMU.flushTLBPage(aligned)
        return true
    }


    /// Give `aligned` a private copy of `source` and map it with `flags`.
    ///
    /// The shared frame's reference is dropped only once the new mapping is in
    /// place, so a failed map leaves the faulting page exactly as it was.
    ///
    /// Nothing is counted here: the page was resident before the write fault and
    /// is resident after it, only behind a different frame.
    private func copyPage(
        from source : PhysicalAddress,
        onto aligned: VirtualAddress,
        flags       : VirtualPageFlags
    ) -> Bool {

        let page: PhysicalPage
        do {
            page = try context.ppm.pointee.alloc(4096)

        } catch { return false }

        let src: UnsafeMutablePointer<UInt8> = context.vmm.pointee.physToVirt(source)
        let dst: UnsafeMutablePointer<UInt8> = context.vmm.pointee.physToVirt(page.address)

        dst.update(from: src, count: Int(UserSpaceLayout.pageSize))

        do {
            try context.vmm.pointee.mapUserPage(
                rootTable: context.rootTablePhysical,
                virtual  : aligned,
                physical : page.address,
                flags    : flags
            )

        } catch {
            try? context.ppm.pointee.free(page)
            return false
        }

        try? context.ppm.pointee.release(source)

        return true
    }


    /// The `growDown` region `address` would extend downward, if there is one.
    private func findGrowableStackVMA(
        below address: VirtualAddress
    ) -> UnsafeMutablePointer<VirtualMemoryArea>? {
        var current = vmaList.head

        while let nodePtr = current {
            let node = nodePtr.pointee

            if node.mappingFlags.contains(.growDown),
               address <  node.startAddress,
               address >= UserSpaceLayout.stackLimit
            { return nodePtr }

            current = node.next
        }

        return nil
    }


    /// Move the start of a `growDown` region down to `address` and back the page
    /// that faulted.
    private mutating func tryGrowStack(
        vmaPtr        : UnsafeMutablePointer<VirtualMemoryArea>,
        downTo address: VirtualAddress
    ) -> Bool {
        let aligned = address & ~(UserSpaceLayout.pageSize - 1)

        guard aligned >= UserSpaceLayout.stackLimit else { return false }

        let oldStart = vmaPtr.pointee.startAddress
        guard aligned < oldStart else { return false }

        let extended = VirtualMemoryArea(
            startAddress: aligned,
            endAddress  : vmaPtr.pointee.endAddress,
            permissions : vmaPtr.pointee.permissions,
            prev        : vmaPtr.pointee.prev,
            next        : vmaPtr.pointee.next,
            backingType : vmaPtr.pointee.backingType,
            mappingFlags: vmaPtr.pointee.mappingFlags
        )
        vmaPtr.pointee = extended

        return materialize(
            vma    : vmaPtr.pointee,
            address: aligned
        )
    }


    /// Back the page holding `address` with a fresh zeroed frame.
    ///
    /// The one place a lazily backed page becomes resident, which is why the
    /// count is taken here and not at the two callers that route faults to it.
    private mutating func materialize(
        vma    : VirtualMemoryArea,
        address: VirtualAddress
    ) -> Bool {
        let page: PhysicalPage
        do {
            page = try context.ppm.pointee.alloc(4096)

        } catch { return false }

        let aligned = address & ~(UserSpaceLayout.pageSize - 1)
        let flags   = vma.permissions.toPageFlags()

        let zeroDest: UnsafeMutablePointer<UInt8> = context.vmm.pointee.physToVirt(page.address)
        zeroDest.initialize(
            repeating: 0,
            count    : Int(UserSpaceLayout.pageSize)
        )

        do {
            try context.vmm.pointee.mapUserPage(
                rootTable: context.rootTablePhysical,
                virtual  : aligned,
                physical : page.address,
                flags    : flags
            )

        } catch {
            try? context.ppm.pointee.free(page)
            return false
        }

        noteMapped(1)

        return true
    }
}
