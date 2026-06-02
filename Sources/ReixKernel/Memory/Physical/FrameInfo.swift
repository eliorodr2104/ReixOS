//
//  FrameInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

@frozen
public struct FrameInfo {
    var refCount : UInt32

    /// Number of still-free blocks on a heap page (only meaningful when
    /// `heapShift != 0`). `BucketsHeap` bumps it on `kfree` and lowers it on
    /// allocation; when it reaches the page's block count the whole page is
    /// empty and is returned to the PPM. 0 for non-heap pages.
    var heapFreeCount: UInt16

    var order    : UInt8
    var flags    : PhysicalPageFlags
    var heapShift: UInt8 // Contains pow shift for size bucket

    init(
        refCount     : UInt32,
        order        : UInt8,
        flags        : PhysicalPageFlags,
        heapShift    : UInt8  = 0, // Zero value is for not heap page
        heapFreeCount: UInt16 = 0
    ) {
        self.refCount      = refCount
        self.order         = order
        self.flags         = flags
        self.heapShift     = heapShift
        self.heapFreeCount = heapFreeCount
    }

    init() {
        self.refCount      = 0
        self.order         = 0
        self.flags         = .none
        self.heapShift     = 0
        self.heapFreeCount = 0
    }
}
