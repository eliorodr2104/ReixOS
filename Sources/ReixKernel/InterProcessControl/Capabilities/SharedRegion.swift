//
//  SharedRegion.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

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

    public var physicalPage: PhysicalPage

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

    /// Pages of the one contiguous physical block behind this region.
    ///
    /// Immutable, and the reason there is no resize: every window and every
    /// mapper derives its bounds from it, and a size that moves under them is a
    /// window that outlives its region.
    public let pageCount   : UInt32

    public let kind        : Kind

    /// A device may retain a physical address after its driver dies. Until a
    /// device supervisor can prove reset completion, published DMA frames must
    /// stay allocated for the rest of the boot, even after every CPU mapping
    /// and capability has gone. Ordinary SHM and unpublished DMA remain reclaimable.
    ///
    /// A property of what has happened to the region, not of what it is: only a
    /// `.dma` region can ever be published, but one that never was stays
    /// reclaimable. `kind` is the immutable half.
    var deviceVisible = false

    /// The budget the frames of this region were charged to when it was
    /// created, with one hold taken on it. `nil` once the charge has ended.
    ///
    /// The frames have one owner, so a process that merely maps somebody else's
    /// region is not charged for it, and the owner stays charged for the whole
    /// life of the region: dropping one of its own references while it still
    /// holds another would let a process hold frames it is not paying for. The
    /// charge ends at the earlier of the region's death and the owner's
    /// teardown, and `disownSharedRegion` is the only thing that ends it.
    ///
    /// The hold is what makes the pointer safe: the cell outlives the process
    /// whenever a region it created does.
    var owner: UnsafeMutablePointer<FrameBudget>? = nil

    public init(
        physicalPage: consuming PhysicalPage,
        references  : UInt32,
        pageCount   : UInt32,
        kind        : Kind = .shared,
        owner       : UnsafeMutablePointer<FrameBudget>? = nil
    ) {
        self.physicalPage = physicalPage
        self.references   = references
        self.pageCount    = pageCount
        self.kind         = kind
        self.owner        = owner
    }

    /// Consumes the region after its last owner drops it. Reclaimable frames go
    /// back to the PPM; device-visible frames remain quarantined. The caller
    /// frees the region's slab storage in either case.
    public consuming func releaseFrame(
        ppm: UnsafeMutablePointer<KernelPPM>
    ) -> PPMError? {

        guard !deviceVisible else { return nil }

        do {
            try ppm.pointee.free(physicalPage)
            return nil

        } catch { return error }
    }
}

@inline(__always)
func retainSharedRegion(_ region: UnsafeMutablePointer<SharedRegion>) {
    rxRetain(region)
}


/// End the creator's charge for `region` and let go of its budget.
///
/// The two moments that call it are the region's own death and the creator's
/// teardown, whichever comes first. Nothing a live process does to one of its
/// references may reach here: a process that drops a capability and keeps a
/// window still holds every frame, and refunding it there is how a loop of
/// create, map and drop would hold memory it never paid for.
///
/// Quarantined DMA frames are never given back to the allocator, so their
/// charge is not given back either.
@inline(__always)
func disownSharedRegion(
    _ region: UnsafeMutablePointer<SharedRegion>,
    heap    : UnsafeMutablePointer<KernelHeap>
) {
    guard let owner = region.pointee.owner else { return }

    if !region.pointee.deviceVisible {
        refundFrames(owner, region.pointee.pageCount)
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

    // The region is dying, so the charge ends here whoever holds the budget.
    disownSharedRegion(region, heap: heap)

    let failure = region.move().releaseFrame(ppm: ppm)
    heap.pointee.kfree(UnsafeMutableRawPointer(region))
    return failure
}
