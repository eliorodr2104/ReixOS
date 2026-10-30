//
//  SharedRegion.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

/// One buddy block behind a shared region: `1 << order` frames from `address`.
///
/// One word and not two. A block head is page aligned, so the low twelve bits
/// of its address are always zero, and the order (at most the buddy's maximum,
/// 11) fits in them. At sixteen bytes an extent would push a region with its
/// inline extents out of the 128-byte slab class and into the 256-byte one.
public struct PhysicalExtent: RXAllocatable {

    private static var orderMask: UInt64 { 0xFFF }

    private let word: UInt64

    init(
        address: PhysicalAddress,
        order  : UInt8
    ) {
        self.word = address | UInt64(order)
    }

    var address: PhysicalAddress { word & ~Self.orderMask }
    var order  : UInt8           { UInt8(truncatingIfNeeded: word & Self.orderMask) }
    var pages  : UInt32          { UInt32(1) << UInt32(order) }
}


public struct SharedRegion: RXObject, ~Copyable {

    /// What the region was minted as, fixed at creation.
    ///
    /// Not `deviceVisible`, which answers a different question and changes over
    /// the region's life. This one never changes: `shmCreate` makes a `.shared`
    /// and `dmaAlloc` makes a `.dma`, and no path turns one into the other.
    /// Without it the only record of the kind was the *capability*'s target
    /// tag, so the object could not check a caller that arrived through the
    /// wrong door.
    public enum Kind: UInt8 {
        case shared
        case dma
    }

    public static var errorMessageAllocation: StaticString = "Shared Region error allocation"

    /// How many live holders this region has.
    ///
    /// Exactly three things count, and they are counted the same: a capability
    /// in a process's table, a window in an address space, and a capability in
    /// flight on an endpoint. The region dies when the number reaches zero,
    /// which is why a window has to hold one of its own - a process that drops
    /// its capability and keeps the mapping still holds the frames.
    ///
    /// Taken by `RendezvousIPC.retain` (table and in flight),
    /// `VMAManager.registerRegion` and `VMAList.split` (windows). Given back by
    /// `RendezvousIPC.release`, `VMAManager.unregister` and `ListRetirement`.
    /// The frame charge is not this count: see `owner`.
    public var references  : UInt32

    /// Pages of the region, and exactly the frames it holds: a `.shared` region
    /// is made of blocks that sum to it. A `.dma` buffer is the one exception,
    /// a single block that may round past it, and the charge follows the block
    /// and not this number: see `framesHeld`.
    ///
    /// Immutable, and the reason there is no resize: every window and every
    /// mapper derives its bounds from it, and a size that moves under them is a
    /// window that outlives its region.
    public let pageCount   : UInt32

    public let kind        : Kind

    /// A device may retain a physical address after its driver dies. Published
    /// DMA frames therefore stay allocated after every CPU mapping and
    /// capability has gone, on `DmaQuarantine`, until a holder of the device
    /// declares it reset. Ordinary SHM and unpublished DMA go straight back.
    ///
    /// A property of what has happened to the region, not of what it is: only a
    /// `.dma` region can ever be published, but one that never was stays
    /// reclaimable. `kind` is the immutable half. The declared reset is the one
    /// thing that clears it, because it is what makes it false.
    var deviceVisible = false

    /// Extents in use, the inline ones first and then the spill's.
    private(set) var extentCount: UInt16 = 0

    /// The budget the frames of this region were charged to when it was
    /// created, with one hold taken on it. `nil` once the charge has ended.
    ///
    /// The frames have one owner, so a process that merely maps somebody else's
    /// region is not charged for it, and the owner stays charged for the whole
    /// life of the region: dropping one of its own references while it still
    /// holds another would let a process hold frames it is not paying for. The
    /// charge ends at the earlier of the frames going back to the PPM and the
    /// owner's teardown, and `disownSharedRegion` is the only thing that ends
    /// it. For most regions the first is their death; for a published buffer
    /// that dies onto `DmaQuarantine` it is the `dmaReclaim` that frees it.
    ///
    /// The hold is what makes the pointer safe: the cell outlives the process
    /// whenever a region it created does.
    var owner: UnsafeMutablePointer<FrameBudget>? = nil

    /// The base of the device window a `.dma` region was minted through, fixed
    /// at creation. Zero, and never read, for a `.shared` one.
    ///
    /// Not an isolation boundary. With no IOMMU any device the holder can drive
    /// reaches the buffer, so this does not say who may transfer into it: it
    /// says which device's reset releases it from `DmaQuarantine`. The base
    /// alone is the key because windows are carved only as the device tree
    /// declared them, and two distinct windows never share one.
    public let device: PhysicalAddress

    /// The next region on `DmaQuarantine`'s list, while this one is on it.
    var nextQuarantined: UnsafeMutablePointer<SharedRegion>? = nil

    /// Extents past the inline ones, from the kernel heap, `nil` until a
    /// region needs more than its cell holds.
    ///
    /// Not charged to the creator's `FrameBudget`, like the region's own cell
    /// and every VMA node: kernel-heap metadata is bounded by what it describes.
    /// Here the bound is tight: a slot covers at least one charged frame, so the
    /// spill is at most sixteen bytes, slab rounding included, per 4 KiB paid for.
    private var spill: UnsafeMutablePointer<PhysicalExtent>? = nil

    /// Ten, where eight would do for the plain binary decomposition of any
    /// count up to `ShmCreate.maxPages` (255 is eight one bits).
    ///
    /// The header above is 48 bytes and eight extents make it 112, which the
    /// slab rounds up to 128 anyway. The two slots after them are therefore
    /// free, and they absorb an order or two split by fragmentation before a
    /// region has to spill. They were four until `device` and the quarantine
    /// link took sixteen bytes, which is what keeps the cell at 128.
    private var extents: InlineArray<10, PhysicalExtent>


    /// A region over one block the caller already holds, a `.dma` one when it
    /// names the `device` window it was minted through.
    ///
    /// The only way a `.dma` region is made, so a DMA buffer is one extent by
    /// construction and `dmaPhysical` has a single address to answer.
    public init(
        physicalPage: consuming PhysicalPage,
        references  : UInt32,
        pageCount   : UInt32,
        device      : PhysicalAddress? = nil,
        owner       : UnsafeMutablePointer<FrameBudget>? = nil
    ) {
        self.references  = references
        self.pageCount   = pageCount
        self.kind        = device == nil ? .shared : .dma
        self.device      = device ?? 0
        self.owner       = owner
        self.extents     = InlineArray(repeating: PhysicalExtent(address: 0, order: 0))
        self.extents[0]  = PhysicalExtent(
            address: physicalPage.address,
            order  : physicalPage.order
        )
        self.extentCount = 1
    }


    /// A `.shared` region with no frames yet. `allocateFrames` gives it its own.
    public init(
        references: UInt32,
        pageCount : UInt32,
        owner     : UnsafeMutablePointer<FrameBudget>? = nil
    ) {
        self.references = references
        self.pageCount  = pageCount
        self.kind       = .shared
        self.device     = 0
        self.owner      = owner
        self.extents    = InlineArray(repeating: PhysicalExtent(address: 0, order: 0))
    }


    /// The frames the region holds, which is what its creator is charged for:
    /// `pageCount` for a `.shared` region, and the whole block for a `.dma`
    /// one, whose single block may round past `pageCount`.
    var framesHeld: UInt32 {
        kind == .dma ? extent(0).pages : pageCount
    }


    /// Extent `index`, counted across the inline ones and the spill.
    @inline(__always)
    func extent(_ index: Int) -> PhysicalExtent {
        index < extents.count ? extents[index] : spill![index - extents.count]
    }


    /// Where page `page` of the region lives.
    ///
    /// Pages are numbered across the extents in order, so a window over the
    /// region is contiguous in virtual memory whatever the frames are in
    /// physical memory. Only a `.dma` region promises the second.
    func physicalAddress(ofPage page: UInt32) -> PhysicalAddress {
        var first: UInt32 = 0

        for index in 0..<Int(extentCount) {
            let extent = extent(index)

            if page - first < extent.pages {
                return extent.address + UInt64(page - first) * UserSpaceLayout.pageSize
            }

            first += extent.pages
        }

        Arch.CPU.panic("shared region page out of range")
    }


    /// Takes exactly `pageCount` frames from `ppm` as buddy blocks, largest
    /// first.
    ///
    /// Five pages are a block of four and a block of one, never the eight a
    /// single block rounds up to. A block of the order the decomposition wants
    /// may not exist even when enough frames are free, so a refused order is
    /// split into the next one down, to order zero if it has to be: these
    /// frames need not be contiguous. A DMA buffer's must, and it is never made
    /// here.
    ///
    /// All or nothing. On a refusal every block already taken goes back to the
    /// PPM and the spill to the heap, so the caller is left an empty cell.
    mutating func allocateFrames(
        ppm : UnsafeMutablePointer<KernelPPM>,
        heap: UnsafeMutablePointer<KernelHeap>
    ) throws(PPMError) {
        guard kind == .shared, extentCount == 0, pageCount > 0 else {
            throw .allocationFailed(reason: .bytesNotValid(Int(pageCount)))
        }

        var remaining = pageCount

        // Free memory only shrinks while this runs, so an order refused once is
        // refused again, and every larger one with it: the order never climbs.
        var order = UInt8(31 - remaining.leadingZeroBitCount)

        while remaining > 0 {
            while UInt32(1) << UInt32(order) > remaining { order -= 1 }

            let block: PhysicalPage
            do {
                block = try ppm.pointee.alloc(Int(UserSpaceLayout.pageSize) << Int(order))

            } catch {
                guard order > 0 else {
                    _ = giveBack(ppm: ppm, heap: heap)
                    throw error
                }

                order -= 1
                continue
            }

            let extent = PhysicalExtent(address: block.address, order: block.order)

            guard append(extent, owed: remaining, heap: heap) else {
                try? ppm.pointee.free(block)
                _ = giveBack(ppm: ppm, heap: heap)
                throw .allocationFailed(reason: .fullMemory)
            }

            remaining -= extent.pages
        }
    }


    /// Records `extent`, spilling to the heap once the cell is full.
    ///
    /// `owed` is what is left to allocate, this extent included. Every extent
    /// covers at least one frame, so that many slots hold every extent still to
    /// come, and the spill sized here never has to grow.
    private mutating func append(
        _ extent: PhysicalExtent,
        owed    : UInt32,
        heap    : UnsafeMutablePointer<KernelHeap>
    ) -> Bool {
        let index = Int(extentCount)

        if index < extents.count {
            extents[index] = extent

        } else {
            if spill == nil {
                guard let storage = heap.pointee.kmallocOrNil(
                    PhysicalExtent.self,
                    Int(owed)
                ) else { return false }

                spill = storage
            }

            spill!.advanced(by: index - extents.count).initialize(to: extent)
        }

        extentCount += 1
        return true
    }


    /// Every extent back to the PPM and the spill back to the heap, leaving the
    /// region with no frames. The first refusal is reported, and the remaining
    /// extents are still given back.
    private mutating func giveBack(
        ppm : UnsafeMutablePointer<KernelPPM>,
        heap: UnsafeMutablePointer<KernelHeap>
    ) -> PPMError? {
        var failure: PPMError? = nil

        for index in 0..<Int(extentCount) {
            let extent = extent(index)

            do {
                try ppm.pointee.free(PhysicalPage(address: extent.address, order: extent.order))

            } catch {
                if failure == nil { failure = error }
            }
        }

        if let spill { heap.pointee.kfree(UnsafeMutableRawPointer(spill)) }

        spill       = nil
        extentCount = 0

        return failure
    }


    /// Consumes the region after its last owner drops it, giving every frame
    /// back to the PPM and the spill to the heap. The caller frees the region's
    /// slab storage.
    ///
    /// A device-visible region is refused and keeps its frames. It never gets
    /// here: `releaseSharedRegion` puts it on `DmaQuarantine` instead, and that
    /// clears the flag once the device is declared reset.
    public consuming func releaseFrames(
        ppm : UnsafeMutablePointer<KernelPPM>,
        heap: UnsafeMutablePointer<KernelHeap>
    ) -> PPMError? {

        guard !deviceVisible else { return nil }

        return giveBack(ppm: ppm, heap: heap)
    }
}

@inline(__always)
func retainSharedRegion(_ region: UnsafeMutablePointer<SharedRegion>) {
    rxRetain(region)
}


/// End the creator's charge for `region` and let go of its budget.
///
/// The two moments that call it are the frames going back to the PPM, which is
/// the region's death or, for a quarantined buffer, its reclaim, and the
/// creator's teardown, whichever comes first. Nothing a live process does to
/// one of its references may reach here: a process that drops a capability and
/// keeps a window still holds every frame, and refunding it there is how a loop
/// of create, map and drop would hold memory it never paid for.
///
/// Called on a published buffer, which a device may still be writing, it ends
/// the charge without a refund. Only the creator's teardown does that, and the
/// budget dies with the process anyway. A published buffer's own death never
/// reaches here: it goes onto `DmaQuarantine` still charged, and the reclaim
/// that clears `deviceVisible` and gives its frames back refunds it here.
@inline(__always)
func disownSharedRegion(
    _ region: UnsafeMutablePointer<SharedRegion>,
    heap    : UnsafeMutablePointer<KernelHeap>
) {
    guard let owner = region.pointee.owner else { return }

    if !region.pointee.deviceVisible {
        refundFrames(owner, region.pointee.framesHeld)
    }

    region.pointee.owner = nil
    releaseBudget(owner, heap: heap)
}


/// The same, for a teardown that may only end the charge of the process it is
/// tearing down: a region somebody else created is not this one's to disown.
@inline(__always)
func disownSharedRegion(
    _ region   : UnsafeMutablePointer<SharedRegion>,
    ownedBy    : UnsafeMutablePointer<FrameBudget>?,
    heap       : UnsafeMutablePointer<KernelHeap>
) {
    guard let ownedBy, region.pointee.owner == ownedBy else { return }

    disownSharedRegion(region, heap: heap)
}

@inline(__always)
func releaseSharedRegion(
    _ region: UnsafeMutablePointer<SharedRegion>,
    ppm   : UnsafeMutablePointer<KernelPPM>,
    heap  : UnsafeMutablePointer<KernelHeap>
) -> PPMError? {
    guard rxRelease(region) else { return nil }

    // A device may still write there: the cell is kept, frames and charge and
    // all, until `dmaReclaim` gives the frames back and ends the charge.
    guard !region.pointee.deviceVisible else {
        DmaQuarantine.admit(region)
        return nil
    }

    // The frames go back now, so the charge ends here whoever holds the budget.
    disownSharedRegion(region, heap: heap)

    let failure = region.move().releaseFrames(ppm: ppm, heap: heap)
    heap.pointee.kfree(UnsafeMutableRawPointer(region))
    return failure
}
