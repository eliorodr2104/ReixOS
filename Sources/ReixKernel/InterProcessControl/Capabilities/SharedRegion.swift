//
//  SharedRegion.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

public struct SharedRegion: RXObject, ~Copyable {

    public static var errorMessageAllocation: StaticString = "Shared Region error allocation"

    public var physicalPage: PhysicalPage
    public var references  : UInt32
    public var pageCount   : UInt32

    /// A device may retain a physical address after its driver dies. Until a
    /// device supervisor can prove reset completion, published DMA frames must
    /// stay allocated for the rest of the boot, even after every CPU mapping
    /// and capability has gone. Ordinary SHM and unpublished DMA remain reclaimable.
    var deviceVisible = false

    public init(
        physicalPage: consuming PhysicalPage,
        references  : UInt32,
        pageCount   : UInt32
    ) {
        self.physicalPage = physicalPage
        self.references   = references
        self.pageCount    = pageCount
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

@inline(__always)
func releaseSharedRegion(
    _ region: UnsafeMutablePointer<SharedRegion>,
    ppm   : UnsafeMutablePointer<KernelPPM>,
    heap  : UnsafeMutablePointer<KernelHeap>
) -> PPMError? {
    guard rxRelease(region) else { return nil }

    let failure = region.move().releaseFrame(ppm: ppm)
    heap.pointee.kfree(UnsafeMutableRawPointer(region))
    return failure
}
