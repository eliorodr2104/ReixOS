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

    /// Releases the owned frame back to the PPM, consuming the region. Called
    /// once the last capability to it is dropped; the caller frees the slab
    /// storage afterwards.
    public consuming func releaseFrame(ppm: UnsafeMutablePointer<KernelPPM>) {
        // TODO: Manage the PPM error
        try? ppm.pointee.free(physicalPage)
    }
}
