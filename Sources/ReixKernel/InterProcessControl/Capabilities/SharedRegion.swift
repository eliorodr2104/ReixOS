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

    public init(
        physicalPage: consuming PhysicalPage,
        references  : UInt32,
        pageCount   : UInt32
    ) {
        self.physicalPage = physicalPage
        self.references   = references
        self.pageCount    = pageCount
    }

    /// Releases the owned frame back to the PPM, consuming the region, and hands
    /// back the PPM's refusal if there was one. Called once the last owner drops
    /// it; the caller frees the slab storage afterwards.
    public consuming func releaseFrame(
        ppm: UnsafeMutablePointer<KernelPPM>
    ) -> PPMError? {

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
