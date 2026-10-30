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
/// Not bounded: every entry is a dead buffer a `.dma` holder published, and
/// those holders are inside the trusted base. Accounted instead. `pages` and
/// `regions` are in `SystemStats`, and the metadata is one 128-byte cell per
/// entry, which describes at least one 4 KiB frame the count already shows.
enum DmaQuarantine: Loggable {

    static let nameLog : StaticString = "[DMA ]"

    private static var head: UnsafeMutablePointer<SharedRegion>? = nil

    /// Frames held out of the PPM, not `pageCount`s: a buffer's one block may
    /// round past what was asked, and every frame of it stays out.
    private(set) static var pages  : UInt32 = 0
    private(set) static var regions: UInt32 = 0

    #if !hasFeature(Embedded)
        /// Forgets the list without following it: the cells belong to a host
        /// fixture's heap, which is gone by the time the next one starts.
        static func reset() {
            head    = nil
            pages   = 0
            regions = 0
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


    /// Gives back every region bound to `device`, and answers the frames that
    /// reached the PPM.
    ///
    /// Only what is on the list, and the list holds only regions nothing
    /// references: a buffer still held, published or not, is never here.
    ///
    /// A block the PPM refuses is said once, for its region, and left out of
    /// the answer. The region leaves the list either way: the refusal is a
    /// fault in the PPM's books, and keeping the cell would not repair them.
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

            if let previous {
                previous.pointee.nextQuarantined = cursor
            } else {
                head = cursor
            }

            let frames = held(by: region)
            pages   -= frames
            regions -= 1

            // The declared reset is what makes the region no longer visible, and
            // with the frames about to go back, what ends its creator's charge.
            region.pointee.deviceVisible = false
            disownSharedRegion(region, heap: heap)

            if let failure = region.move().releaseFrames(ppm: ppm, heap: heap) {
                Self.error("quarantined DMA region released after a reset but one of its frames was refused, \(failure.description)")

            } else {
                released += frames
            }

            heap.pointee.kfree(UnsafeMutableRawPointer(region))
        }

        return released
    }


    /// A `.dma` region is one extent, so its frames are that block's.
    @inline(__always)
    private static func held(by region: UnsafeMutablePointer<SharedRegion>) -> UInt32 {
        region.pointee.extent(0).pages
    }
}
