//
//  PageRetirement.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Clearing leaf descriptors and giving frames back, the page work every
/// retirement operation is made of.
///
/// A namespace and not a method on `VMAManager`, because a page retire needs
/// nothing from the manager: no VMA list, no heap. An operation holding a
/// pointer back to the manager to reach this would alias the `inout self` of the
/// syscall that built it, for no gain.
enum PageRetirement {

    /// Pages one retirement step examines.
    ///
    /// Also the width of the batch `retire` collects before it invalidates and
    /// releases it, and the two must move together: `InlineArray` needs its
    /// count as a literal, so the storage there repeats this number.
    ///
    /// The step bounds the *scan* and not the frames released. A `.noReserve`
    /// region nobody ever touched has no resident page at all: a step bounded by
    /// frames would walk the whole region probing page tables without ever
    /// filling a batch.
    static let pagesPerBatch: UInt64 = 32

    /// Beyond this many pages a range is retired with one full TLB flush
    /// instead of per-page invalidations.
    private static let rangeInvalidationLimit: UInt64 = 32


    /// Pages this kernel has retired since boot, all address spaces together.
    ///
    /// A running total sampled around a drive, and not a value handed back per
    /// call, because the caller that has to act on it is `VMAManager` and the
    /// operations between it and here are cut into steps that a checkpoint may
    /// abandon: a suspension would drop a returned count on the floor, while a
    /// delta taken across `Preemption.run` charges each entry exactly the pages
    /// that entry retired. Wraps, and is only ever read as a difference.
    ///
    /// A step of one retirement never drives another, and the interrupt window
    /// opens no path back into this file, so no reader can observe a partial
    /// update of the counter it is bracketing.
    static var retiredPages: UInt64 = 0


    /// End of the batch a step starting at `cursor` covers, never past `limit`.
    static func batchEnd(
        from cursor: VirtualAddress,
        limit      : VirtualAddress
    ) -> VirtualAddress {
        let end = cursor + pagesPerBatch * UserSpaceLayout.pageSize

        return end > limit ? limit : end
    }


    /// Clear the leaf descriptors of `[start, end)` and, for an owned region,
    /// release each frame only after its translation is gone.
    ///
    /// Frames are collected in a fixed-size batch, invalidated, and released
    /// only then. Releasing each frame the instant its own descriptor is cleared
    /// leaves the buddy allocator free to re-issue frames the TLB still
    /// translates writable, for a window as long as the range itself. The batch
    /// lives on the stack: two callers are rollbacks running under memory
    /// pressure and must not need the heap.
    ///
    /// The addresses are read from the user page tables, which `mapUserPage`
    /// only ever fills at L3. `physicalAddressOf` terminates on whichever
    /// descriptor maps the address, so a 2 MiB block mapping would yield an
    /// interior frame address and the allocator would be asked to free a block
    /// it never issued, which `PPMError.frameNotBlockHead` refuses.
    ///
    /// Only resident pages are invalidated, which relies on the invariant this
    /// function establishes: a cleared descriptor never keeps a cached
    /// translation, so an absent one has nothing to retire. `materialize`
    /// depends on the same invariant when it maps a fresh page.
    ///
    /// Every page that had a translation is added to `retiredPages`, whatever
    /// the backing: the count is of mappings dropped and not of frames freed.
    ///
    /// ## Why only `.anonymous` reaches the allocator
    ///
    /// Any other backing is retired by the branch below, which clears the leaf
    /// descriptors, invalidates the range and returns without a single `release`.
    /// That is not a simplification of the batched path, it is the contract of
    /// those regions: `.fileBacked` maps permanently resident initrd frames that
    /// belong to a reserved range rather than to this address space, `.shared`
    /// frames are owned by the `SharedRegion` that counts its own references, and
    /// `.device` frames are not RAM the buddy allocator has ever seen. Releasing
    /// any of them here would hand the allocator a frame it never issued, or drop
    /// a reference this layer never took.
    ///
    /// So the batch, the deferred release and the frame ownership reasoning above
    /// all describe the `.anonymous` path alone. See `BackingType.fileBacked`.
    static func retire(
        context: PagingContext,
        start  : VirtualAddress,
        end    : VirtualAddress,
        backing: BackingType
    ) {
        // Unmap only, for every backing this address space does not own: the
        // translations go, the frames stay with whoever owns them.
        guard backing == .anonymous else {
            var va = start
            while va < end {
                
                if context.vmm.pointee.physicalAddressOf(
                    rootTable: context.rootTablePhysical,
                    virtual  : va
                ) != nil { retiredPages &+= 1 }

                try? context.vmm.pointee.unmapUserPage(
                    rootTable: context.rootTablePhysical,
                    virtual  : va
                )
                va += UserSpaceLayout.pageSize
            }

            invalidate(start: start, end: end)
            return
        }

        // The batch width is read back from the storage so the two cannot drift;
        // `InlineArray` needs its count as a literal.
        var virtuals  = InlineArray<32, VirtualAddress>(repeating: 0)
        var physicals = InlineArray<32, PhysicalAddress>(repeating: 0)

        var chunkStart = start
        while chunkStart < end {
            var pending = 0
            var va      = chunkStart

            while va < end, pending < virtuals.count {
                if let phys = context.vmm.pointee.physicalAddressOf(
                    rootTable: context.rootTablePhysical,
                    virtual  : va
                ) {
                    try? context.vmm.pointee.unmapUserPage(
                        rootTable: context.rootTablePhysical,
                        virtual  : va
                    )

                    virtuals[pending]  = va
                    physicals[pending] = phys
                    pending += 1
                }

                va += UserSpaceLayout.pageSize
            }
            chunkStart = va

            guard pending > 0 else { continue }

            retiredPages &+= UInt64(pending)

            var index = 0
            while index < pending {
                Arch.MMU.flushTLBPageNoSync(virtuals[index])
                index += 1
            }
            Arch.MMU.flushTLBSync()

            index = 0
            while index < pending {
                try? context.ppm.pointee.release(physicals[index])
                index += 1
            }
        }
    }


    /// Retire the cached translations of `[start, end)` once its leaf
    /// descriptors have been cleared.
    static func invalidate(
        start: VirtualAddress,
        end  : VirtualAddress
    ) {
        let pages = (end - start) / UserSpaceLayout.pageSize

        guard pages <= rangeInvalidationLimit else {
            Arch.MMU.flushTLB()
            return
        }

        var va = start
        while va < end {
            Arch.MMU.flushTLBPageNoSync(va)
            va += UserSpaceLayout.pageSize
        }

        Arch.MMU.flushTLBSync()
    }
}
