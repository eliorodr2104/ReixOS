//
//  MMU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

import ReixABI

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


// MARK: - Publishing code

extension AArch64MMU {

    /// CTR_EL0 as `loadCacheType` read it at boot.
    ///
    /// Zero until then, which decodes as the policy that assumes the least:
    /// clean every 4-byte line, then invalidate the whole instruction cache.
    static var cacheType: UInt64 = 0

    @_silgen_name("read_cache_type")
    static func readCacheType() -> UInt64

    @_silgen_name("read_main_id")
    static func readMainID() -> UInt64

    /// Early Cortex-A53 cleans need an invalidation too. Loaded at boot with
    /// the cache type; no publication reads the CPU's identity again.
    static var cleanCacheNeedsInvalidate: Bool = false

    /// Bytes one `dc zva` zeroes, as `loadCacheType` read DCZID_EL0.
    ///
    /// Zero means never use `dc zva`: before `loadCacheType`, when DZP forbids
    /// it, and when the block is outside 16...2048 bytes.
    static var zeroBlockBytes: Int = 0

    @_silgen_name("read_dczid")
    static func readZeroIdentification() -> UInt64

    @_silgen_name("zero_blocks")
    static func zeroBlocks(
        _ base    : UnsafeMutableRawPointer,
        count     : UInt64,
        blockBytes: UInt64
    )

    /// Read CTR_EL0, MIDR_EL1 and DCZID_EL0 before the first page of code is
    /// published.
    public static func loadCacheType() {
        cacheType = readCacheType()

        let midr = readMainID()

        // Errata 819472, 826319, 827319 and 824069: Cortex-A53 r0p0-r0p2.
        // Match the model without variant/revision, then their combined range.
        cleanCacheNeedsInvalidate = midr & 0xFF0F_FFF0 == 0x410F_D030
                                 && midr & 0x00F0_000F <= 2

        let dczid = readZeroIdentification()
        let block = 4 << Int(dczid & 0xF)
        zeroBlockBytes = dczid & 0x10 == 0 && block >= 16 && block <= 2048 ? block : 0
    }

    /// Zeroes `count` bytes at `base` with `dc zva` over the whole blocks inside
    /// the range and `RawBytes.fill` on the two edges. Returns `false`, having
    /// written nothing, when the range is under four blocks or `dc zva` is off.
    ///
    /// The MMU is tested on every call on purpose: the block size is loaded after
    /// `enable_mmu`, but a core running Swift before its own MMU is on (SMP
    /// bring-up) would find it already set, and `dc zva` on Device memory is an
    /// alignment fault.
    static func zeroCacheBlocks(_ base: UnsafeMutableRawPointer, count: Int) -> Bool {
        let block = zeroBlockBytes
        guard block != 0, count >= 4 &* block, isMMUEnabled() else { return false }

        let mask  = UInt(block &- 1)
        let start = UInt(bitPattern: base)
        let end   = start &+ UInt(count)
        let first = (start &+ mask) & ~mask
        let last  = end & ~mask

        RawBytes.fill(base, with: 0, count: Int(bitPattern: first &- start))
        zeroBlocks(
            base + Int(bitPattern: first &- start),
            count     : UInt64((last &- first) / UInt(block)),
            blockBytes: UInt64(block)
        )
        RawBytes.fill(
            base + Int(bitPattern: last &- start),
            with : 0,
            count: Int(bitPattern: end &- last)
        )
        return true
    }

    /// Not IDC: a store reaches the instruction side only through a clean to
    /// the point of unification.
    static var cleanNeeded: Bool { cacheType & (1 << 28) == 0 }

    /// Not DIC: the instruction cache may hold a line the store made stale.
    static var invalidationNeeded: Bool { cacheType & (1 << 29) == 0 }

    /// L1Ip is PIPT, so `ic ivau` through the kernel alias reaches the very
    /// lines a fetch through the user alias would hit. A VIPT cache may not.
    static var instructionCacheIsPIPT: Bool { (cacheType >> 14) & 0b11 == 0b11 }

    /// The IVIPT rule makes translation changes transparent on VIPT and PIPT
    /// caches: an unchanged PA needs no second publication under a new ASID.
    ///
    /// Keep the conservative path for AIVIVT and the reserved encoding formerly
    /// used for VPIPT, which is also what a cache type not yet loaded decodes as.
    static var canReusePublishedInstructions: Bool { (cacheType >> 14) & 0b10 != 0 }

    /// Bytes per line, from DminLine and IminLine, which count 4-byte words.
    static var dataLine       : UInt64 { 4 << ((cacheType >> 16) & 0xF) }
    static var instructionLine: UInt64 { 4 << (cacheType & 0xF) }

    @_silgen_name("clean_dcache_pou")
    static func cleanDataCacheToPoU(
        _ base: UnsafeMutableRawPointer,
        size  : UInt64,
        line  : UInt64
    )

    @_silgen_name("clean_dcache_poc")
    static func cleanDataCacheToPoC(
        _ base: UnsafeMutableRawPointer,
        size  : UInt64,
        line  : UInt64
    )

    @_silgen_name("invalidate_icache_lines")
    static func invalidateInstructionLines(
        _ base: UnsafeMutableRawPointer,
        size  : UInt64,
        line  : UInt64
    )

    @_silgen_name("invalidate_icache_all")
    static func invalidateInstructionCache()

    @_silgen_name("synchronize_instruction_stream")
    static func synchronizeInstructionStream()

    /// The per-range half of publishing code written through the kernel alias:
    /// the clean to the point of unification and, on a PIPT cache, the
    /// invalidation of the same lines.
    ///
    /// Nothing staged is fetchable yet. Every range belongs to a batch that
    /// ends in exactly one `completeInstructionPublication()`, and its bytes
    /// may not change in between. `@inline(never)` keeps the symbol the
    /// `icache-batch` post-check reads.
    @inline(never)
    public static func stageInstructions(_ base: UnsafeMutableRawPointer, size: UInt64) {
        if cleanNeeded {
            if cleanCacheNeedsInvalidate {
                cleanDataCacheToPoC(base, size: size, line: dataLine)
            } else {
                cleanDataCacheToPoU(base, size: size, line: dataLine)
            }
        }

        guard invalidationNeeded, instructionCacheIsPIPT else { return }

        invalidateInstructionLines(base, size: size, line: instructionLine)
    }

    /// The once-per-batch half: one `ic ialluis` when the cache needs one and
    /// cannot be reached by address, otherwise only the wait and the `isb`.
    @inline(never)
    public static func completeInstructionPublication() {
        guard invalidationNeeded, !instructionCacheIsPIPT else {
            synchronizeInstructionStream()
            return
        }

        invalidateInstructionCache()
    }
}
