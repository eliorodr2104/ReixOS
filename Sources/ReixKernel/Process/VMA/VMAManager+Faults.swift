//
//  VMAManager+Faults.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

import ReixABI

/// What the VMA layer did with a fault, and what is left for its caller to do.
///
/// Three answers and not a `Bool`, because two of the failures are different
/// deaths: a refusal is a program that asked for something its mappings never
/// granted, while running out of frames is a request that was legitimate and
/// could not be served. Reporting the second as a segfault blames the program
/// for the machine's state, and retrying it forever is the same fault on the
/// same instruction for as long as memory stays short.
public enum FaultOutcome: Equatable {

    /// The access is now backed. The faulting instruction may be restarted.
    case handled

    /// Nothing here can fulfil the access. The process has to die.
    case refused

    /// A serviceable fault with no frame to back it.
    case outOfMemory
}


extension VMAManager {

    /// Decide what to do with a synchronous abort raised at `address` by
    /// `access`.
    public mutating func handlePageFault(
        at address: VirtualAddress,
        cause     : FaultCause,
        access    : FaultAccess
    ) -> FaultOutcome {

        guard address >= UserSpaceLayout.userMin,
              address <  UserSpaceLayout.userMax
        else { return .refused }

        if let vmaPtr = vmaList.search(at: address) {
            return serviceFault(
                vmaPtr : vmaPtr,
                address: address,
                cause  : cause,
                access : access
            )
        }

        // The other road to `materialize`, under the same rule: growing the
        // stack for a fetch it will never allow is a frame taken for a death.
        if let growable = findGrowableStackVMA(below: address) {
            guard growable.pointee.permissions.grant(access) else { return .refused }

            return tryGrowStack(
                vmaPtr: growable,
                downTo: address
            )
        }

        return .refused
    }


    /// Route a fault that landed inside a registered region to whatever can still
    /// fulfil it.
    ///
    /// A translation fault is serviced for any access the region's own
    /// permissions grant, and the missing descriptor decides none of that: a page
    /// of a lazily backed region is legitimately read, written, or fetched from
    /// where the region says so. What the region does not grant is another
    /// matter. Backing a fetch into a region without `.execute`, or a store into
    /// one without `.write`, buys a zeroed frame and one retry, and the retry
    /// takes the permission fault the access was always going to take. So the
    /// answer is given before the allocator is asked, which is what "an
    /// illegitimate access terminates without allocating" has to mean on a
    /// machine with 4 MiB: a frame taken for a death is a frame.
    ///
    /// A permission fault is the opposite. The descriptor is there and says no,
    /// and the one refusal this layer knows how to lift is the write bit it took
    /// out itself at clone time. So the copy-on-write path is reached by a *data
    /// write* on a `.copyOnWrite` region the VMA says is writable, and by nothing
    /// else. An instruction fetch on an NX page, a read the mapping never
    /// granted, a write to a region without `.write`: none of those become
    /// legitimate by allocating a frame, and each one used to be handed to the
    /// copy-on-write path, which refused it after reading the frame's reference
    /// count. Refusing on the access kind instead is what stops an execute fault
    /// on a writable NX page from looking resolvable.
    private mutating func serviceFault(
        vmaPtr : UnsafeMutablePointer<VirtualMemoryArea>,
        address: VirtualAddress,
        cause  : FaultCause,
        access : FaultAccess
    ) -> FaultOutcome {
        let vma = vmaPtr.pointee

        switch cause {
            case .translation:
                guard vma.mappingFlags.contains(.noReserve)
                   || vma.mappingFlags.contains(.growDown),
                      vma.permissions.grant(access)
                else { return .refused }

                return materialize(
                    vma    : vma,
                    address: address
                )

            case .permission:
                guard case .write = access,
                      vma.mappingFlags.contains(.copyOnWrite),
                      vma.permissions.contains(.write)
                else { return .refused }

                return serviceCopyOnWrite(
                    vma    : vma,
                    address: address
                )

            case .alignment, .access: return .refused
        }
    }


    /// Take the write fault of a copy-on-write page.
    ///
    /// Reached only from `serviceFault`, which has already established that this
    /// is a data write on a writable `.copyOnWrite` region.
    ///
    /// A frame nobody else holds needs no copy at all: the region is writable and
    /// only the descriptor is still read-only, so the permission is restored in
    /// place. That is also the path a parent lands on after its child is gone.
    ///
    /// `.copyOnWrite` is deliberately left on the region after a promotion. The
    /// flag names a region whose pages *may* be shared and every page decides for
    /// itself by its reference count, so clearing it on the first promotion would
    /// declare the whole region private while its other pages are still shared.
    /// Clearing it at the right moment would need a count of the region's
    /// still-shared pages, which is a per-region counter maintained by every
    /// clone, promotion, copy and retirement; the flag costs one test per
    /// permission fault instead.
    ///
    /// The two branches are two different operations on the same descriptor and
    /// each carries its own invalidation: a permission change is a protect and
    /// needs a TLB invalidation, a new frame is a replace and needs
    /// break-before-make. Neither is invalidated here.
    private mutating func serviceCopyOnWrite(
        vma    : VirtualMemoryArea,
        address: VirtualAddress
    ) -> FaultOutcome {

        let aligned = address & ~(UserSpaceLayout.pageSize - 1)

        guard let phys = context.vmm.pointee.physicalAddressOf(
            rootTable: context.rootTablePhysical,
            virtual  : aligned
        ) else { return .refused }

        let flags = vma.permissions.toPageFlags()

        let references = context.ppm.pointee.refCount(of: phys)

        guard references > 0 else { return .refused }

        guard references > 1 else {

            do {
                try context.vmm.pointee.protectUserPage(
                    rootTable: context.rootTablePhysical,
                    virtual  : aligned,
                    flags    : flags,
                    type     : vma.memoryType
                )

            } catch { return .refused }

            return .handled
        }

        return copyPage(
            from : phys,
            onto : aligned,
            flags: flags,
            type : vma.memoryType
        )
    }


    /// Give `aligned` a private copy of `source` and map it with `flags`.
    ///
    /// The shared frame's reference is dropped only once the new mapping is in
    /// place, so a failed map leaves the faulting page exactly as it was. That
    /// one release is the exact counterpart of the retain `RegionClone` took for
    /// this address space: this process no longer maps the shared frame, and the
    /// reference it was holding on it goes with the mapping.
    ///
    /// Nothing is counted here: the page was resident before the write fault and
    /// is resident after it, only behind a different frame.
    ///
    /// A refused allocation leaves every one of those unchanged, and is
    /// `.outOfMemory` rather than a refusal: the write was legitimate and the
    /// machine could not serve it. A map that throws after the copy is the same
    /// answer, with the new frame given straight back so a death under memory
    /// pressure does not also leak the last frame it took.
    ///
    /// That difference is the whole reason this is `replaceUserPage` and not an
    /// install: the descriptor is valid and its output address changes under
    /// it, which is the case the architecture requires break-before-make for.
    private func copyPage(
        from source : PhysicalAddress,
        onto aligned: VirtualAddress,
        flags       : VirtualPageFlags,
        type        : MemoryType
    ) -> FaultOutcome {

        // The private copy is a page this address space did not hold before;
        // the shared reference it replaces is given back below.
        guard chargeFrames(context.budget, 1) else { return .outOfMemory }

        let page: PhysicalPage
        do {
            page = try context.ppm.pointee.alloc(4096)

        } catch {
            refundFrames(context.budget, 1)
            return .outOfMemory
        }

        let src: UnsafeMutablePointer<UInt8> = context.vmm.pointee.physToVirt(source)
        let dst: UnsafeMutablePointer<UInt8> = context.vmm.pointee.physToVirt(page.address)

        dst.update(from: src, count: Int(UserSpaceLayout.pageSize))

        do {
            try context.vmm.pointee.replaceUserPage(
                rootTable: context.rootTablePhysical,
                virtual  : aligned,
                physical : page.address,
                flags    : flags,
                type     : type
            )

        } catch {
            try? context.ppm.pointee.free(page)
            refundFrames(context.budget, 1)
            return .outOfMemory
        }

        if (try? context.ppm.pointee.release(source)) != nil {
            refundFrames(context.budget, 1)
        }

        return .handled
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
    ) -> FaultOutcome {
        let aligned = address & ~(UserSpaceLayout.pageSize - 1)

        guard aligned >= UserSpaceLayout.stackLimit else { return .refused }

        let oldStart = vmaPtr.pointee.startAddress
        guard aligned < oldStart else { return .refused }

        let extended = VirtualMemoryArea(
            startAddress: aligned,
            endAddress  : vmaPtr.pointee.endAddress,
            permissions : vmaPtr.pointee.permissions,
            prev        : vmaPtr.pointee.prev,
            next        : vmaPtr.pointee.next,
            backingType : vmaPtr.pointee.backingType,
            mappingFlags: vmaPtr.pointee.mappingFlags,
            memoryType  : vmaPtr.pointee.memoryType
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
    ///
    /// An install and not a replace: both callers arrive from a translation
    /// fault, so the leaf descriptor is invalid and nothing needs breaking.
    ///
    /// A refused allocation is `.outOfMemory` for the same reason it is in
    /// `copyPage`: the access was one this region promises to serve, so the
    /// machine and not the program is what could not keep the promise.
    private mutating func materialize(
        vma    : VirtualMemoryArea,
        address: VirtualAddress
    ) -> FaultOutcome {
        guard chargeFrames(context.budget, 1) else { return .outOfMemory }

        let page: PhysicalPage
        do {
            page = try context.ppm.pointee.alloc(4096)

        } catch {
            refundFrames(context.budget, 1)
            return .outOfMemory
        }

        let aligned = address & ~(UserSpaceLayout.pageSize - 1)
        let flags   = vma.permissions.toPageFlags()

        let zeroDest: UnsafeMutablePointer<UInt8> = context.vmm.pointee.physToVirt(page.address)
        zeroDest.initialize(
            repeating: 0,
            count    : Int(UserSpaceLayout.pageSize)
        )

        do {
            try context.vmm.pointee.installUserPage(
                rootTable: context.rootTablePhysical,
                virtual  : aligned,
                physical : page.address,
                flags    : flags,
                type     : vma.memoryType,
                budget   : context.budget
            )

        } catch {
            try? context.ppm.pointee.free(page)
            refundFrames(context.budget, 1)
            return .outOfMemory
        }

        noteMapped(1)

        return .handled
    }
}
