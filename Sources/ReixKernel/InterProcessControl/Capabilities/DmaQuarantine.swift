//
//  DmaQuarantine.swift
//  ReixOS
//

/// Published DMA buffers nobody holds any more, kept out of the PPM until the
/// device each was minted through is declared reset.
///
/// A device may keep writing to an address after the driver that gave it is
/// gone, and with no IOMMU nothing stops it, so these frames cannot simply be
/// freed. They used to be dropped on the floor instead: out of the PPM for the
/// rest of the boot, counted nowhere, and lost to every restart of the driver.
/// Here they are counted, and `dmaReclaim` gives back the ones bound to a
/// device whose holder says it has been reset.
///
/// An entry keeps its creator's charge and the hold on its budget, because
/// the charge lasts as long as the frames are out of the PPM. A creator that
/// dropped its buffer and lives on keeps paying until the reclaim. One that
/// died still holding it ended the charge at teardown, and the entry names no
/// budget. One that dropped it and died afterwards leaves its budget held by
/// the entry alone, and the reclaim's refund is the last thing that cell sees.
///
/// The region cell itself is the entry, linked through `nextQuarantined`, and
/// not a smaller record of its one extent and its device. A record would be a
/// heap allocation on the death path, which has nobody to report a refusal to,
/// and a refusal there is the silent leak again. The cell is already allocated
/// and already holds both.
///
/// When the PPM refuses a block at reclaim time, the entry is neither freed
/// nor forgotten. The refusal is diagnosed (`PhysicalPageManager.diagnose`) and
/// the reading kept in the cell as `refusal`, which is all that marks a refused
/// entry from a waiting one on the same list. A refused entry keeps its frames
/// out and its creator's charge on, because guessing a block's size from books
/// that just contradicted themselves is how a neighbour gets freed.
///
/// A refused entry is never released again, by anything. Each later reclaim
/// of its device reads the books once more, and the one thing it may do is
/// close an entry whose block they now call free: the memory is back already,
/// so closing it frees nothing. A block that reads live after a refusal is not
/// a block that healed. The PPM keeps no owner tag, so a live block of the same
/// order at the same address may be somebody else's allocation by then, and
/// freeing it would free a stranger's memory. Every reading but `.free` keeps
/// the entry as it is, and only a change of reading is said.
///
/// Not bounded: every entry is a dead buffer a `.dma` holder published, and
/// those holders are inside the trusted base. Accounted instead. Every count
/// below is in `SystemStats`, and the metadata is one 128-byte cell per entry,
/// which describes at least one 4 KiB frame the counts already show.
enum DmaQuarantine: Loggable {

    static let nameLog : StaticString = "[DMA ]"

    private static var head: UnsafeMutablePointer<SharedRegion>? = nil

    /// Frames held out of the PPM, not `pageCount`s: a buffer's one block may
    /// round past what was asked, and every frame of it stays out. `pages` and
    /// `regions` are the entries waiting for a reset, `refusedPages` those whose
    /// reset was declared and whose block the PPM refused.
    private(set) static var pages       : UInt32 = 0
    private(set) static var regions     : UInt32 = 0
    private(set) static var refusedPages: UInt32 = 0

    /// Entries closed because their block was already free when the reclaim
    /// came. Every one is a quarantined frame that went back early, while a
    /// device could still write it, and may have been handed out since.
    private(set) static var doubleFrees : UInt32 = 0

    #if !hasFeature(Embedded)
        /// Forgets the list without following it: the cells belong to a host
        /// fixture's heap, which is gone by the time the next one starts.
        static func reset() {
            head         = nil
            pages        = 0
            regions      = 0
            refusedPages = 0
            doubleFrees  = 0
        }
    #endif


    /// Takes a published region whose last reference has just gone, frames,
    /// cell and charge and all.
    static func admit(_ region: UnsafeMutablePointer<SharedRegion>) {
        region.pointee.nextQuarantined = head
        head = region

        pages   += held(by: region)
        regions += 1
    }


    /// Gives back every region bound to `device` that the PPM takes, and
    /// answers the frames that reached it.
    ///
    /// Only what is on the list, and the list holds only regions nothing
    /// references: a buffer still held, published or not, is never here.
    ///
    /// A region whose block is given back, or found already free, is closed:
    /// its creator is refunded and the cell freed. One whose block is refused
    /// stays, refused, with its charge. A block found already free is not in
    /// the answer, since this call gave nothing back for it.
    static func release(
        device: PhysicalAddress,
        ppm   : UnsafeMutablePointer<KernelPPM>,
        heap  : UnsafeMutablePointer<KernelHeap>
    ) -> UInt32 {
        var released: UInt32 = 0
        var previous: UnsafeMutablePointer<SharedRegion>? = nil
        var cursor   = head

        while let region = cursor {
            // Read before the cell can be freed.
            cursor = region.pointee.nextQuarantined

            guard region.pointee.device == device else {
                previous = region
                continue
            }

            let frames  = held(by: region)
            let refused = region.pointee.refusal != nil
            let state   = settle(region, ppm: ppm)

            if let state, state != .free {
                if !refused {
                    pages        -= frames
                    regions      -= 1
                    refusedPages += frames

                } else if state != region.pointee.refusal {
                    let block = region.pointee.extent(0)
                    Self.error("refused DMA block at 0x\(hex: block.address) still kept, the books now say \(state.description)")
                }

                region.pointee.refusal = state
                previous = region
                continue
            }

            if let previous {
                previous.pointee.nextQuarantined = cursor
            } else {
                head = cursor
            }

            if refused {
                refusedPages -= frames
            } else {
                pages   -= frames
                regions -= 1
            }

            if state == nil {
                released += frames

            } else {
                doubleFrees += 1

                let block = region.pointee.extent(0)
                Self.error("quarantined DMA block at 0x\(hex: block.address) was already free: it went back while a device could still write it, and may have been handed out since")
            }

            close(region, heap: heap)
        }

        return released
    }


    /// Gives `region`'s block back, answering `nil` when the PPM took it and
    /// what its books say when it did not.
    ///
    /// A region refused before is only read, never given back: see the type's
    /// doc for why a block that reads live is not one to free.
    private static func settle(
        _ region: UnsafeMutablePointer<SharedRegion>,
        ppm     : UnsafeMutablePointer<KernelPPM>
    ) -> PhysicalBlockState? {
        let block = region.pointee.extent(0)

        guard region.pointee.refusal == nil else {
            return ppm.pointee.diagnose(block.address, order: block.order)
        }

        do {
            try ppm.pointee.free(PhysicalPage(address: block.address, order: block.order))
            return nil

        } catch {
            let state = ppm.pointee.diagnose(block.address, order: block.order)

            // A block found free is the caller's to report, louder.
            if state != .free {
                Self.error("quarantined DMA block at 0x\(hex: block.address) refused by the PPM and kept, the books say \(state.description): \(error.description)")
            }

            return state
        }
    }


    /// Ends a region whose frames are back in the PPM: the reset declared, the
    /// creator refunded and its hold let go, the cell freed.
    private static func close(
        _ region: UnsafeMutablePointer<SharedRegion>,
        heap    : UnsafeMutablePointer<KernelHeap>
    ) {
        region.pointee.deviceVisible = false
        disownSharedRegion(region, heap: heap)

        heap.pointee.kfree(UnsafeMutableRawPointer(region))
    }


    /// A `.dma` region is one extent, so its frames are that block's.
    @inline(__always)
    private static func held(by region: UnsafeMutablePointer<SharedRegion>) -> UInt32 {
        region.pointee.extent(0).pages
    }
}
