//
//  VMAManager+Lifecycle.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

extension VMAManager {

    /// Walk every registered VMA, unmap each mapped page and release the frame
    /// behind it when the backing is this address space's to free (`.anonymous`).
    /// For `.fileBacked` and `.shared` only the PTE is cleared: the backing block
    /// is freed by whoever produced it.
    ///
    /// The whole list is moved out of the manager first, so `ListRetirement` owns
    /// the chain it walks and pops each node before retiring its pages. That is
    /// what keeps the chain well-formed at every point: the kernel heap threads its
    /// free list through the first 8 bytes of a released block, which is
    /// `startAddress`, so a node freed while still linked hands every later walker
    /// a corrupted region. Taking the list away also denies `serviceFault` any
    /// chance to fault a page back into a region already being torn down.
    ///
    /// `AddressSpaceTeardown` is `.latencyOnly`: see `PreemptionRegion` for why a
    /// dying address space must not park a continuation.
    public mutating func teardown() {
        let pending = vmaList

        vmaList = LinkedList(
            head      : nil,
            tail      : nil,
            minAddress: pending.minAddress,
            maxAddress: pending.maxAddress
        )

        brkVMA       = nil
        currentBreak = 0

        // Zeroed up front rather than counted down as the walk goes: the whole
        // address space is going, so nothing can be resident once it returns.
        resetResidentPages()

        // The VMAs they walk are about to be freed, and nobody will re-enter the
        // syscalls that would have finished them.
        suspendedDecommit = nil
        suspendedUnmap    = nil

        _ = Preemption.run(
            AddressSpaceTeardown.self,
            ListRetirement(
                heap   : heap,
                context: context,
                nodes  : pending
            )
        )
    }


    /// Reproduce the parent's address space into `self` (the child of a
    /// `split`/`fork`).
    ///
    /// Every parent VMA is registered here carrying the parent's backing type, and
    /// its resident pages are then shared or copied according to that backing: only
    /// `.anonymous` regions are this address space's to duplicate, so a writable one
    /// is mapped read-only in both processes and marked `.copyOnWrite`. See
    /// `RegionClone` for what a step does and what it leaves behind.
    ///
    /// The flush covers the throwing exits too, and has to: the parent's own
    /// descriptors are rewritten in place as the walk proceeds while `mapUserPage`
    /// retires no translation, so an exit without it leaves the parent holding
    /// read-only descriptors in memory and stale writable entries in the TLB, with
    /// no later path flushing on its behalf.
    public mutating func cloneRegions(from parent: VMAManager) throws(VMAError) {
        defer { Arch.MMU.flushTLB() }

        _ = try Preemption.run(
            AddressSpaceClone.self,
            RegionClone(
                manager   : managerPointer(),
                context   : context,
                parentRoot: parent.context.rootTablePhysical,
                parentBrk : parent.brkVMA,
                from      : parent.vmaList.head
            )
        )
    }
}
