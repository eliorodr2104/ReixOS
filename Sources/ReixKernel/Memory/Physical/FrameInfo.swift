//
//  FrameInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

/// One record per 4 KiB frame of RAM, so its size is paid `ramSize / 4096` times
/// over. The field order and the packed `orderAndShift` byte below are what keep
/// it at a stride of 8 bytes instead of 12.
///
/// The all-zero pattern is load-bearing and must keep meaning "free, unowned, no
/// heap role". Both initializers have to produce it, because two call sites rely
/// on a different one: `PhysicalPageManager.clearRangeMetadata` writes `init()`
/// to hand frames back to the buddy, while the boot array fill in
/// `PhysicalPageManager.init` repeats the memberwise
/// `FrameInfo(refCount: 0, order: 0, flags: .none)`, which is what every frame
/// starts life with.
@frozen
public struct FrameInfo {
    var refCount : UInt32

    /// Number of still-free blocks on a heap page (only meaningful when
    /// `heapShift != 0`). `BucketsHeap` bumps it on `kfree` and lowers it on
    /// allocation; when it reaches the page's block count the whole page is
    /// empty and is returned to the PPM. 0 for non-heap pages.
    var heapFreeCount: UInt16

    var flags: PhysicalPageFlags

    /// `order` in the low nibble, `heapShift` in the high one.
    ///
    /// Two separate `UInt8`s pushed the struct to 9 bytes and so to a stride of
    /// 12, a third of the array wasted on padding. Both values are bounded well
    /// inside 4 bits, so the nibbles cannot truncate anything real:
    ///
    /// - `order` is a buddy order. `BuddyAllocator.maxOrder` is 11 and its
    ///   `blockSize` throws `pageOrderInvalid` above it, so no block can carry
    ///   more. The one larger value stored is
    ///   `PhysicalPageManager.blockInteriorOrder`, the block-interior sentinel,
    ///   which is 15 for exactly this reason and still above every real order.
    ///
    /// - `heapShift` is a slab bucket shift. `SlabCore.alloc` clamps it up to
    ///   `minShift`, 3, and its `size <= pageSize` guard caps it at
    ///   `log2(4096)`, 12; `SlabCore.free` rejects anything outside 3...12. 0
    ///   stays "not a heap page".
    ///
    /// The setters mask their argument, so a caller that ever broke one of those
    /// bounds would corrupt only its own field and not the neighbour's.
    private var orderAndShift: UInt8

    @inline(__always)
    var order: UInt8 {
        get { orderAndShift & 0x0F }
        set { orderAndShift = (orderAndShift & 0xF0) | (newValue & 0x0F) }
    }

    @inline(__always)
    var heapShift: UInt8 {
        get { orderAndShift >> 4 }
        set { orderAndShift = (orderAndShift & 0x0F) | ((newValue & 0x0F) << 4) }
    }

    init(
        refCount     : UInt32,
        order        : UInt8,
        flags        : PhysicalPageFlags,
        heapShift    : UInt8  = 0, // Zero value is for not heap page
        heapFreeCount: UInt16 = 0
    ) {
        self.refCount      = refCount
        self.heapFreeCount = heapFreeCount
        self.flags         = flags
        self.orderAndShift = (order & 0x0F) | ((heapShift & 0x0F) << 4)
    }

    init() {
        self.refCount      = 0
        self.heapFreeCount = 0
        self.flags         = .none
        self.orderAndShift = 0
    }
}
