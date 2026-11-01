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

    @_silgen_name("asid_bits")
    public static func asidBits() -> UInt64

    /// Publish freshly written code through the kernel's cached alias. The
    /// target user root need not be active; invalidation covers every alias.
    @_silgen_name("synchronize_instruction_cache")
    public static func synchronizeInstructionCache(
        _ base: UnsafeMutableRawPointer,
        size: UInt64
    )
    
    /// Every translation, global ones included: `tlbi vmalle1is`. Only for when
    /// the kernel's own entries changed, which after boot is never; a user
    /// address space is retired with `flushTLB(asid:)`.
    @_silgen_name("flush_tlb")
    public static func flushTLB()

    /// Every translation `asid` tagged, walk-cache entries included, and no
    /// global one: `dsb ishst; tlbi aside1is; dsb ish; isb`. Self-contained.
    @_silgen_name("flush_tlb_asid")
    public static func flushTLB(asid: ASID)

    /// `tlbi vale1is` for `virtual` under `asid`: the last-level entry alone,
    /// for a leaf cleared or rewritten while every table above it stayed.
    ///
    /// No barrier on either side. The descriptor store before it needs its
    /// `pageTableBarrier()`, and a run of these ends in one `flushTLBSync()`.
    @_silgen_name("flush_tlb_leaf_nosync")
    public static func flushTLBLeafNoSync(_ virtual: VirtualAddress, asid: ASID)

    /// `tlbi vae1is` for `virtual` under `asid`: every level of the walk, for a
    /// table that was unlinked. The same contract as `flushTLBLeafNoSync`.
    @_silgen_name("flush_tlb_table_nosync")
    public static func flushTLBTableNoSync(_ virtual: VirtualAddress, asid: ASID)

    /// `dsb ish` + `isb`: completes a run of `NoSync` invalidations.
    @_silgen_name("flush_tlb_sync")
    public static func flushTLBSync()

    /// `dsb ishst`, makes every page-table store issued so far visible to the
    /// hardware table walker. Required at each descriptor write site that is
    /// not immediately followed by a TLB invalidation.
    @_silgen_name("page_table_barrier")
    public static func pageTableBarrier()

    /// Writes back and drops every cache line over `[base, base + size)`, then
    /// waits for it to have happened.
    ///
    /// Used before handing bytes written through the cached kernel mapping to
    /// a device through a non-cacheable mapping.
    @_silgen_name("clean_dcache_range")
    public static func cleanDataCacheRange(
        _ base: UnsafeMutableRawPointer,
        size  : UInt64
    )

    /// Install `rootTable` in TTBR0_EL1 tagged with `asid`, without any TLB
    /// invalidation: the outgoing space's non-global entries stay cached and
    /// simply stop matching. `asid` 0 is reserved for the kernel identity root.
    ///
    /// Sound for a tag that was just issued because of the rule `ASIDAllocator`
    /// keeps: a tag goes back only after `flushTLB(asid:)` emptied it.
    @_silgen_name("switch_user_address_space")
    public static func switchUserAddressSpace(
        _ rootTable: PhysicalAddress,
        asid       : ASID
    )
    
}
