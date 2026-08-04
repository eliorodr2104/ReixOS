//
//  PhysicalPageManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//


public struct PhysicalPageManager<A: Allocator>: Loggable {
    
    public static var nameLog : StaticString { "[PPM ]" }
    public static var logLevel: LogLevel     { .info    }
    
    private let allocator     : A
    
    public  let ramStart      : UInt64
    public  let ramSize       : UInt64
        
    public  var framesMetadata: UnsafeMutablePointer<FrameInfo>?
    
    
    /// Order written on every frame of a block except its first, so a frame that
    /// is not a block head can be told apart from one that is.
    ///
    /// `UInt8.max` and not a new `PhysicalPageFlags` bit, because `release` has to
    /// load `order` anyway to rebuild the `PhysicalPage` it frees: testing that one
    /// register is free, where a `flags` test would add a load to the path every
    /// anonymous page fault takes. `BuddyAllocator.maxOrder` is 11 and its
    /// `blockSize` rejects anything above it, so no real block can carry this value
    /// and no valid `release` can ever be refused by mistake.
    private static var blockInteriorOrder: UInt8 { .max }


    public func alloc(
        _ bytes  : Int,
        flag     : PhysicalPageFlags = .none,
        heapShift: UInt8 = 0
    ) throws(PPMError) -> PhysicalPage {
        
        guard framesMetadata != nil else {
            throw .metadataInconsistency
        }
        
        do {
            let frame         = try allocator.alloc(bytes)
            let indexMetadata = Int((frame.address - ramStart) / 4096)
            
            let metadata = framesMetadata!.advanced(by: indexMetadata)
            metadata.pointee.refCount  = 1
            metadata.pointee.order     = frame.order
            metadata.pointee.flags     = flag
            metadata.pointee.heapShift = heapShift

            markInteriorFrames(after: indexMetadata, order: frame.order)

            return frame
            
        } catch { throw .allocationFailed(reason: error) }
        
    }


    /// Stamps every frame of an order-N block except its first as block interior.
    ///
    /// Only the head used to be written, so the other frames of a multi-page block
    /// kept whatever metadata a previous life had left them. That matters because
    /// `release` derives the block order from the metadata of whatever address it is
    /// handed: given an interior frame it would rebuild a differently sized
    /// `PhysicalPage` and hand *that* to the buddy allocator, which is heap
    /// corruption and not a leak. Marking the interior is what turns it into
    /// `.frameNotBlockHead`.
    ///
    /// It is a landmine rather than a live bug: no current caller feeds an interior
    /// address (see `release`), and a second, incidental guard stands in front of it
    /// anyway, `free` rejecting `refCount == 0`, which every frame coming out of the
    /// buddy has. Both of those are properties of today's call sites, not of this
    /// type, which is exactly why the check belongs here.
    ///
    /// `refCount` is left at 0 deliberately. An interior frame is not something
    /// anybody may hold a reference to, and 0 keeps that incidental guard standing
    /// alongside the explicit one instead of replacing it.
    ///
    /// `1 ..< (1 << order)` is empty for an order-0 block, so the single-page path,
    /// which every anonymous page fault takes, pays the loop's first bound check and
    /// nothing else: no extra store, no extra load.
    @inline(__always)
    private func markInteriorFrames(
        after headIndex: Int,
        order          : UInt8
    ) {
        for offset in 1..<(1 << Int(order)) {
            let metadata = framesMetadata!.advanced(by: headIndex + offset)

            metadata.pointee.refCount      = 0
            metadata.pointee.order         = Self.blockInteriorOrder
            metadata.pointee.flags         = .none
            metadata.pointee.heapShift     = 0
            metadata.pointee.heapFreeCount = 0
        }
    }

    
    public func free(_ page: consuming PhysicalPage) throws(PPMError) {
        try free(page, allowProtected: false)
    }

    public func freeOwnedKernelPage(_ page: consuming PhysicalPage) throws(PPMError) {
        try free(page, allowProtected: true)
    }

    @inline(__always)
    private func free(
        _ page        : consuming PhysicalPage,
        allowProtected: Bool
    ) throws(PPMError) {
        guard framesMetadata != nil else {
            throw .metadataInconsistency
        }
        
        let indexMetadata = Int((page.address - ramStart) / 4096)
        var metadata = framesMetadata![indexMetadata]
        let flag = metadata.flags
        
        guard metadata.refCount > 0 else {
            throw .invalidRefCount(Int(metadata.refCount))
        }
        
        guard metadata.order == page.order else {
            throw .pageOrderMismatch(expected: page.order, provided: metadata.order)
        }
        
        if allowProtected {
            guard !flag.contains(.reserved) else {
                throw .protectedMemoryViolation
            }
            
        } else {
            guard !flag.contains(.kernel), !flag.contains(.reserved) else {
                throw .protectedMemoryViolation
            }
        }

        metadata.refCount -= 1
        
        do {
            if metadata.refCount == 0 {
                metadata.flags = .none
                try allocator.free(page)
            }

            framesMetadata![indexMetadata] = metadata
            
        } catch { throw .allocationFailed(reason: error) }
    }
    
    
    public mutating func applyFramesMetadataVirtualOffset(_ offset: UInt64) {
        guard let framesMetadata = self.framesMetadata else { return }

        let virtualAddress  = UInt64(UInt(bitPattern: framesMetadata)) + offset
        self.framesMetadata = UnsafeMutablePointer<FrameInfo>(bitPattern: UInt(virtualAddress))

        Self.boot("Frame metadata mapped into high-half.")
    }
    
    
    /// Adds a reference to the frame backing `address`.
    ///
    /// The bound check is not dressing: `address - ramStart` underflows into a
    /// huge `UInt64` for anything below `ramStart`, and an address at or past
    /// `ramEnd` indexes off the end of `framesMetadata`. The COW path feeds
    /// physical addresses straight out of page tables, so a stray value has to
    /// fault here rather than corrupt the metadata array.
    public mutating func retain(_ address: PhysicalAddress) throws(PPMError) {
        guard address >= ramStart, address < ramStart + ramSize else {
            throw .invalidRefCount(Int(bitPattern: UInt(address)))
        }

        let indexMetadata = Int((address - ramStart) / 4096)
        framesMetadata!.advanced(by: indexMetadata).pointee.refCount += 1
    }
    
    /// Drops a reference to the frame backing `address`, which has to be the head
    /// of its block.
    ///
    /// The order is read back from the metadata rather than asked of the caller,
    /// because every caller here holds a physical address and not a `PhysicalPage`:
    /// a COW fault and a range retirement both read theirs straight out of a page
    /// table, which carries no order at all. That is what makes the head-ness check
    /// necessary: an interior address would rebuild a block of the wrong size and
    /// hand it to the buddy allocator.
    ///
    /// It throws rather than panicking because every current call site is a teardown
    /// or an unwind that has nothing to roll back, and killing the machine over a
    /// frame is a worse outcome than losing it. The error is logged here all the
    /// same, since each of those call sites reaches this through `try?`: without the
    /// line the frame would go quietly missing, which is the failure mode this is
    /// meant to end.
    public mutating func release(_ address: PhysicalAddress) throws(PPMError) {
        
        guard address >= ramStart, address < ramStart + ramSize else {
            throw .invalidRefCount(Int(bitPattern: UInt(address)))
        }
        
        let meta  = framesMetadata!.advanced(by: Int((address - ramStart) / 4096))
        let order = meta.pointee.order

        guard order != Self.blockInteriorOrder else {
            Self.error("release of 0x\(hex: address) refused: frame is inside a block, not its head.")
            throw .frameNotBlockHead
        }

        try free(PhysicalPage(address: address, order: order))
    }


    /// References held on the frame backing `address`.
    ///
    /// An out-of-range address reports `0`, which callers read as "not shared",
    /// rather than running past the metadata array. Same bounding rationale as
    /// `retain`.
    ///
    /// An interior frame of a block reports `0` too, and is left non-throwing on
    /// purpose. Signalling it here would mean either a signature the one caller,
    /// `VMAManager.serviceFault`, cannot use, or a `flags`/`order` load on the path
    /// every copy-on-write fault takes. Neither is worth it, because `0` is already
    /// the conservative answer: `serviceFault` reads it as "shared" and takes a
    /// private copy, and the `release` it then performs on the old frame is the call
    /// that reports the interior address and refuses.
    public mutating func refCount(of address: PhysicalAddress) -> UInt32 {
        guard address >= ramStart, address < ramStart + ramSize else {
            return 0
        }

        let indexMetadata = Int((address - ramStart) / 4096)
        return framesMetadata!.advanced(by: indexMetadata).pointee.refCount
    }
    
    // MARK: - Helpers
    
    private func setRangeMetadata(
        from: PhysicalAddress,
        to  : PhysicalAddress,
        flag: PhysicalPageFlags
        
    ) {
        let start = Int((from - ramStart) / 4096)
        let end   = Int((to   - ramStart) / 4096)
        
        for i in start..<end {
            var frame = framesMetadata![i]
            
            frame.refCount  = 1
            frame.flags     = flag
                
            framesMetadata![i] = frame
        }
    }
    
    
    private func freeSegment(
        from a: UInt64,
        to   b: UInt64
    ) throws(PPMError) {
        let s = (a + 0xFFF) & ~0xFFF
        let e = b & ~0xFFF
        
        if s < e {
            do {
                try allocator.addFreeRange(from: s, to: e)
                
            } catch { throw .allocationFailed(reason: error) }
        }
    }
}


/// A block of RAM that is already occupied when the allocator is built and
/// must therefore never enter its free lists.
///
/// The occupied blocks are modelled as a list rather than as one high-water
/// mark because they are genuinely disjoint: the kernel image sits at the
/// bottom of RAM while the boot loader drops the initrd and the DTB around the
/// middle. Collapsing them into a single span up to the highest end address
/// throws away every hole between them, and on a small machine that is nearly
/// all of the RAM: at 5 MiB QEMU ends the DTB exactly at the top of RAM, so
/// the collapsed span covers everything and the allocator is handed nothing.
private struct ReservedRange {

    let start: PhysicalAddress
    let end  : PhysicalAddress

    var isEmpty: Bool { start >= end }

    /// Aligned outward to whole pages, so a page that is only partly occupied
    /// is still withheld, and clamped to RAM.
    ///
    /// The clamp is not defensive dressing: the initrd and DTB bounds come
    /// straight from the device tree, and both `setRangeMetadata` and the
    /// buddy index off `ramStart` with no bound of their own.
    init(
        from   : PhysicalAddress,
        to     : PhysicalAddress,
        ramLow : PhysicalAddress,
        ramHigh: PhysicalAddress
    ) {
        let low  = max(from & ~0xFFF, ramLow)
        let high = to >= ramHigh ? ramHigh : min((to + 0xFFF) & ~0xFFF, ramHigh)

        self.start = low
        self.end   = high > low ? high : low
    }
}


extension PhysicalPageManager where A == BuddyAllocator {

    /// Lays the bookkeeping out above the kernel image, withholds the ranges the
    /// boot state still occupies, and donates everything else to the buddy.
    ///
    /// Three ranges are withheld: the kernel image plus the bitmap, free lists
    /// and frame metadata stacked immediately above it, then the initrd, then
    /// the DTB. The initrd belongs there as much as the kernel does, because the
    /// ELF images the process manager is about to load still live in it and
    /// nothing else in the tree withholds those frames. A small RAM size hides
    /// the omission: the loader puts the initrd halfway up RAM, so the allocator
    /// has to chew through megabytes before it ever reaches it.
    ///
    /// The three ranges arrive in the boot loader's order and are sorted
    /// ascending, because the sweep that follows recognises a free hole as the
    /// gap between one block's end and the next block's start. That sweep keeps
    /// `cursor` on the first frame not yet accounted for, which also makes
    /// overlapping or nested blocks harmless: they never move it backwards, so
    /// `setRangeMetadata` and `freeSegment` stay in agreement, every boundary
    /// either of them sees being one of these page-aligned edges.
    init() throws(PPMError) {
        let evtEndAddr     = getOfaddressWithSymbol(of: &_evt_end)
        let kernelTotalEnd = getOfaddressWithSymbol(of: &_kernel_total_end)

        self.ramStart             = Kernel.platformInfo.ram.base
        self.ramSize              = Kernel.platformInfo.ram.size
        
        let ramEnd                = Kernel.platformInfo.ram.base + Kernel.platformInfo.ram.size
        
        let bitmapAddr: UInt64    = (kernelTotalEnd + 0xFFF) & ~0xFFF
        
        let totalPages            = Kernel.platformInfo.ram.size / 4096
        let bitmapBytes           = (totalPages + 7) / 8
        
        let freeListsAddr         = (bitmapAddr + bitmapBytes + 0xFFF) & ~0xFFF
        // 12 free lists (orders 0...maxOrder), one LinkedList<FreeBlock> each:
        // the buddy stores list heads/tails here, not 12 bare UInt64s.
        let freeListsSize: UInt64 = 12 * UInt64(MemoryLayout<LinkedList<FreeBlock>>.stride)

        let framesMetadataAddress = (freeListsAddr + freeListsSize + 0xFFF) & ~0xFFF
        let framesMetadataSize    = totalPages * UInt64(MemoryLayout<FrameInfo>.stride)
        
        let reservedEnd           = (framesMetadataAddress + framesMetadataSize + 0xFFF) & ~0xFFF
        
        self.framesMetadata         = UnsafeMutablePointer(bitPattern: UInt(framesMetadataAddress))
        framesMetadata?.initialize(repeating: FrameInfo(refCount: 0, order: 0, flags: .none), count: Int(totalPages))
        
        // `_evt_end` is inside `.text` and so already below `_kernel_total_end`;
        // folded in anyway, in case a linker script moves the vectors out.
        let kernelBlockEnd = max(reservedEnd, (evtEndAddr + 0xFFF) & ~0xFFF)

        self.allocator = BuddyAllocator(
            start           : Kernel.platformInfo.ram.base,
            size            : Kernel.platformInfo.ram.size,
            bitmapAddress   : bitmapAddr,
            freeListsAddress: freeListsAddr
        )

        var reserved: InlineArray<3, ReservedRange> = [
            ReservedRange(
                from   : Kernel.platformInfo.ram.base,
                to     : kernelBlockEnd,
                ramLow : ramStart,
                ramHigh: ramEnd
            ),
            ReservedRange(
                from   : Kernel.platformInfo.initrdStart,
                to     : Kernel.platformInfo.initrdEnd,
                ramLow : ramStart,
                ramHigh: ramEnd
            ),
            ReservedRange(
                from   : Kernel.platformInfo.dtbBase,
                to     : Kernel.platformInfo.dtbBase + UInt64(Kernel.platformInfo.dtbSize),
                ramLow : ramStart,
                ramHigh: ramEnd
            )
        ]

        // Insertion sort: three elements, and the sweep below needs them ascending.
        for i in 1..<reserved.count {
            let item = reserved[i]
            var j    = i

            while j > 0, reserved[j - 1].start > item.start {
                reserved[j] = reserved[j - 1]
                j -= 1
            }

            reserved[j] = item
        }

        // One pass: reserve each occupied block, donate the hole in front of it.
        var cursor = ramStart

        for i in 0..<reserved.count {
            let block = reserved[i]
            guard !block.isEmpty, block.end > cursor else { continue }

            if block.start > cursor {
                try freeSegment(from: cursor, to: block.start)
            }

            setRangeMetadata(
                from: max(block.start, cursor),
                to  : block.end,
                flag: .reserved
            )

            cursor = block.end
        }

        if cursor < ramEnd {
            try freeSegment(from: cursor, to: ramEnd)
        }

        Self.boot("Physical Page Manager ready.")
    }
}
