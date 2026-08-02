//
//  MMU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct AArch64MMU {
    
    private init() {  }
    
    @_silgen_name("enable_mmu")
    public static func enableMMU(
        lowTable : PhysicalAddress,
        highTable: PhysicalAddress
    )
    
    @_silgen_name("is_mmu_enabled")
    public static func isMMUEnabled() -> Bool
    
    @_silgen_name("flush_tlb")
    public static func flushTLB()

    /// Invalidate only the translation for `virtual` (4 KiB granule), across
    /// every ASID, inner-shareable. Self-contained: it publishes the pending
    /// page-table stores and synchronizes the instruction stream itself.
    @_silgen_name("flush_tlb_page")
    public static func flushTLBPage(_ virtual: VirtualAddress)

    /// Barrier-free variant of `flushTLBPage` for invalidating a run of pages.
    /// Every call must be followed, once, after the last page, by
    /// `flushTLBSync()`.
    @_silgen_name("flush_tlb_page_nosync")
    public static func flushTLBPageNoSync(_ virtual: VirtualAddress)

    /// `dsb ish` + `isb`: completes a batch of `flushTLBPageNoSync(_:)`.
    @_silgen_name("flush_tlb_sync")
    public static func flushTLBSync()

    /// `dsb ishst`, makes every page-table store issued so far visible to the
    /// hardware table walker. Required at each descriptor write site that is
    /// not immediately followed by a TLB invalidation.
    @_silgen_name("page_table_barrier")
    public static func pageTableBarrier()

    /// Install `rootTable` in TTBR0_EL1 tagged with `asid`, without any TLB
    /// invalidation: the outgoing space's non-global entries stay cached and
    /// simply stop matching. `asid` 0 is reserved for the kernel identity root.
    @_silgen_name("switch_user_address_space")
    public static func switchUserAddressSpace(
        _ rootTable: PhysicalAddress,
        asid       : ASID
    )
    
}
