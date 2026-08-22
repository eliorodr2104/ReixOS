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


    /// 4 KiB frames this machine has, the whole of RAM and not the part the
    /// buddy was given: the reserved blocks are memory too, and a total that
    /// moved with them would make the free share unreadable.
    public private(set) var totalPages: UInt64 = 0

    /// 4 KiB frames currently spoken for, whether by a block the buddy issued
    /// or by one of the ranges withheld at boot.
    ///
    /// Maintained in whole blocks, `1 << order` frames at a time, so a
    /// multi-page allocation is counted once by the head that owns it. Free
    /// pages are `totalPages - allocatedPages` and are not stored: two counters
    /// for one quantity is one of them going stale.
    public private(set) var allocatedPages: UInt64 = 0


    /// The frames `init` actually withheld for the device tree blob, which is
    /// not the same span as `dtbBase ..< dtbBase + dtbSize`: see the sweep.
    ///
    /// Kept so `reclaimDeviceTree` can hand back exactly those frames and no
    /// others. Zeroed once it has, which is what makes it idempotent.
    private var deviceTreeStart: PhysicalAddress = 0
    private var deviceTreeEnd  : PhysicalAddress = 0


    /// Order written on every frame of a block except its first, so a frame that
    /// is not a block head can be told apart from one that is.
    ///
    /// A reserved order and not a new `PhysicalPageFlags` bit, because `release` has
    /// to load `order` anyway to rebuild the `PhysicalPage` it frees: testing that
    /// one register is free, where a `flags` test would add a load to the path every
    /// anonymous page fault takes. `BuddyAllocator.maxOrder` is 11 and its
    /// `blockSize` rejects anything above it, so no real block can carry this value
    /// and no valid `release` can ever be refused by mistake.
    ///
    /// 15 rather than `UInt8.max`: `FrameInfo` keeps `order` in a nibble, and this
    /// is the largest value that nibble holds.
    private static var blockInteriorOrder: UInt8 { 15 }


    /// - Note: `mutating` for the accounting alone. Every call site reaches the
    ///   manager through a pointer, so the pointee is the one that is bumped and
    ///   no caller had to change.
    public mutating func alloc(
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

            allocatedPages &+= UInt64(1) << UInt64(frame.order)

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

    
    public mutating func free(_ page: consuming PhysicalPage) throws(PPMError) {
        try free(page, allowProtected: false)
    }

    public mutating func freeOwnedKernelPage(_ page: consuming PhysicalPage) throws(PPMError) {
        try free(page, allowProtected: true)
    }

    @inline(__always)
    private mutating func free(
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
        
        let releasedPages = UInt64(1) << UInt64(page.order)

        do {
            if metadata.refCount == 0 {
                metadata.flags = .none
                try allocator.free(page)

                allocatedPages &-= releasedPages
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


    /// Hands the device tree blob's frames to the buddy allocator.
    ///
    /// The blob is read exactly once, by platform discovery, which copies every
    /// field it needs into `PlatformInfo` before this type exists. QEMU rounds the
    /// tree it generates up to 1 MiB, a quarter of the RAM this kernel targets, so
    /// withholding it for the life of the machine is the largest single waste at
    /// boot. The only pointers into the blob anything keeps are
    /// `PlatformInfo.bootargs` and `PlatformInfo.stdoutPath`, which the caller
    /// clears before calling this: the buddy overlays a free-list node on the
    /// first 16 bytes of every block it is handed, so the blob is gone the moment
    /// the donation below runs.
    ///
    /// The span freed is the one the sweep in `init` attributed to the DTB and not
    /// `dtbBase ..< dtbBase + dtbSize`. Those differ when the blob overlaps the
    /// kernel image or the initrd, and the sweep clamps both ends: the start up
    /// past what an earlier block withheld, the end down to where a later block
    /// begins. A frame two blocks cover therefore stays with the one that still
    /// needs it.
    ///
    /// Idempotent, and a no-op when the blob lay outside RAM or was covered whole
    /// by another block.
    ///
    /// Both failure paths are logged here and not at the call site, which reaches
    /// this through `try?` because a reclaim that does not pay must not fold the
    /// boot. Without the lines a megabyte would go quietly missing, and the second
    /// path really does lose it: the metadata is already cleared by then, so the
    /// frames belong to nobody and no later pass looks for them again.
    ///
    /// - Returns: bytes returned to the allocator.
    @discardableResult
    public mutating func reclaimDeviceTree() throws(PPMError) -> UInt64 {
        guard framesMetadata != nil else {
            Self.error("device tree reclaim refused: frame metadata is not mapped.")
            throw .metadataInconsistency
        }

        guard deviceTreeEnd > deviceTreeStart else { return 0 }

        let start = deviceTreeStart
        let end   = deviceTreeEnd

        // Metadata first, and the extent dropped with it: a throwing donation
        // then leaks the frames instead of leaving them owned twice over.
        clearRangeMetadata(from: start, to: end)

        deviceTreeStart = 0
        deviceTreeEnd   = 0

        do {
            try freeSegment(from: start, to: end)

        } catch {
            Self.error("device tree reclaim lost \((end - start) / 1024) KiB at 0x\(hex: start): the allocator refused the donation.")
            throw error
        }

        let reclaimedPages = (end - start) / 4096
        let reclaimedBytes = reclaimedPages * 4096

        allocatedPages &-= reclaimedPages

        Self.boot("Device tree reclaimed: \(reclaimedBytes / 1024) KiB.")

        return reclaimedBytes
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


    /// Puts a range's frames back into the state a frame the buddy holds free is
    /// in, which is the zero `FrameInfo` every frame starts life with.
    ///
    /// Deliberately not `setRangeMetadata(flag: .none)`: that writes
    /// `refCount = 1`, which is what an owned frame looks like, and `free` would
    /// then let the next holder drop a reference nobody ever took.
    private func clearRangeMetadata(
        from: PhysicalAddress,
        to  : PhysicalAddress
    ) {
        let start = Int((from - ramStart) / 4096)
        let end   = Int((to   - ramStart) / 4096)

        for i in start..<end {
            framesMetadata![i] = FrameInfo()
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

    /// Marks the one block that stops being occupied once boot is over, so the
    /// sweep can record the frames it withheld and `reclaimDeviceTree` give them
    /// back.
    ///
    /// Named for the DTB rather than for the property, because exactly one range
    /// may carry it: the sweep keeps a single extent, and a second block claiming
    /// to be the device tree would overwrite the first one's. The kernel image and
    /// its bookkeeping are the running kernel, and the initrd's frames are live
    /// user memory `ImageSharing` maps read-only into running address spaces, so
    /// neither can ever be one.
    let isDeviceTree: Bool

    var isEmpty: Bool { start >= end }

    /// Aligned outward to whole pages, so a page that is only partly occupied
    /// is still withheld, and clamped to RAM.
    ///
    /// The clamp is not defensive dressing: the initrd and DTB bounds come
    /// straight from the device tree, and both `setRangeMetadata` and the
    /// buddy index off `ramStart` with no bound of their own.
    init(
        from        : PhysicalAddress,
        to          : PhysicalAddress,
        ramLow      : PhysicalAddress,
        ramHigh     : PhysicalAddress,
        isDeviceTree: Bool = false
    ) {
        let low  = max(from & ~0xFFF, ramLow)
        let high = to >= ramHigh ? ramHigh : min((to + 0xFFF) & ~0xFFF, ramHigh)

        self.start        = low
        self.end          = high > low ? high : low
        self.isDeviceTree = isDeviceTree
    }
}


extension PhysicalPageManager where A == BuddyAllocator {

    /// Lays the bookkeeping out above the kernel image, withholds the ranges the
    /// boot state still occupies, and donates everything else to the buddy.
    ///
    /// Three ranges are withheld: the kernel image plus the frame metadata, free
    /// lists and bitmap packed immediately above it, then the initrd, then
    /// the DTB. The initrd belongs there as much as the kernel does: `ImageSharing`
    /// maps immutable ELF segments straight out of these frames into EL0, shared
    /// read-only across every process that loads the same image, so they are live
    /// user memory and not just an archive awaiting a future read. Handing one of
    /// these frames to the allocator would corrupt whatever address space still
    /// maps it. See `BackingType.fileBacked` for what unwinds this reservation
    /// once the FS server lands. A small RAM size hides the omission: the loader
    /// puts the initrd halfway up RAM, so the allocator has to chew through
    /// megabytes before it ever reaches it.
    ///
    /// The kernel block starts at `_kernel_start` and not at the base of RAM.
    /// QEMU loads a raw AArch64 image 512 KiB into RAM and only writes the
    /// handful of instructions that jump to it at the base, so starting the block
    /// there withheld half a megabyte of untouched RAM for the life of the
    /// machine, an eighth of the 4 MiB this kernel targets. That stub has already
    /// run by the time any of this executes, and QEMU restores it from its ROM
    /// blob on reset, so nothing here has to preserve it.
    ///
    /// The bookkeeping above the image is one arena and not three regions: frame
    /// metadata, then the free-list heads, then the bitmap, with the rounding to a
    /// page boundary done once at `reservedEnd`. Rounding each piece up on its own
    /// spent a page per piece, and two of the three are tiny: at the 4 MiB floor the
    /// bitmap is 128 bytes and the free-list table 192, so 8 KiB of frames went on
    /// 320 bytes of state. The metadata leads because its size is the one that
    /// scales with RAM, `ramSize / 4096` records of 8 bytes, which is a whole number
    /// of pages whenever RAM is a multiple of 2 MiB: the other two then sit in the
    /// tail of its last page and cost nothing. That is one page back at 4 MiB.
    /// At 128 MiB the three span the same 66 pages either way, the bitmap being a
    /// full page there and the old layout's waste already under one.
    ///
    /// The three ranges arrive in the boot loader's order and are sorted
    /// ascending, because the sweep that follows recognises a free hole as the
    /// gap between one block's end and the next block's start. That sweep keeps
    /// `cursor` on the first frame not yet accounted for, which also makes
    /// overlapping or nested blocks harmless: they never move it backwards, so
    /// `setRangeMetadata` and `freeSegment` stay in agreement, every boundary
    /// either of them sees being one of these page-aligned edges.
    init() throws(PPMError) {
        let kernelImageStart = getOfaddressWithSymbol(of: &_kernel_start)
        let evtEndAddr       = getOfaddressWithSymbol(of: &_evt_end)
        let kernelTotalEnd   = getOfaddressWithSymbol(of: &_kernel_total_end)

        self.ramStart             = Kernel.platformInfo.ram.base
        self.ramSize              = Kernel.platformInfo.ram.size

        self.totalPages           = Kernel.platformInfo.ram.size / 4096
        self.allocatedPages       = 0

        let ramEnd                = Kernel.platformInfo.ram.base + Kernel.platformInfo.ram.size

        let totalPages            = Kernel.platformInfo.ram.size / 4096

        // One arena, page rounded once at `reservedEnd` and not between its parts.
        // The metadata leads because its size is the only one measured in pages.
        let framesMetadataAddress = (kernelTotalEnd + 0xFFF) & ~0xFFF
        let framesMetadataSize    = totalPages * UInt64(MemoryLayout<FrameInfo>.stride)

        // Aligned for the list type rather than assumed to be, though a metadata
        // size that is a whole number of strides already lands there.
        let freeListsAddr         = Self.alignUp(
            framesMetadataAddress + framesMetadataSize,
            to: MemoryLayout<LinkedList<FreeBlock>>.alignment
        )
        // Asked of the allocator that fills the region, so a raised `maxOrder`
        // widens the reservation and the memset behind it together.
        let freeListsSize         = UInt64(BuddyAllocator.freeListsBytes)

        // Last and unaligned on purpose: a byte array has nothing to satisfy, so it
        // takes whatever the page the free lists ended in has left.
        let bitmapAddr            = freeListsAddr + freeListsSize
        let bitmapBytes           = (totalPages + 7) / 8

        let reservedEnd           = (bitmapAddr + bitmapBytes + 0xFFF) & ~0xFFF

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
                from   : kernelImageStart,
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
                from        : Kernel.platformInfo.dtbBase,
                to          : Kernel.platformInfo.dtbBase + UInt64(Kernel.platformInfo.dtbSize),
                ramLow      : ramStart,
                ramHigh     : ramEnd,
                isDeviceTree: true
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

            let withheldStart = max(block.start, cursor)

            setRangeMetadata(
                from: withheldStart,
                to  : block.end,
                flag: .reserved
            )

            allocatedPages &+= (block.end - withheldStart) / 4096

            // Recorded after the clamp, so what is handed back later is what was
            // withheld here and not whatever the device tree claimed.
            if block.isDeviceTree {
                deviceTreeStart = withheldStart
                deviceTreeEnd   = block.end
            }

            cursor = block.end
        }

        trimDeviceTreeExtent(against: reserved)

        if cursor < ramEnd {
            try freeSegment(from: cursor, to: ramEnd)
        }

        Self.boot("Physical Page Manager ready.")
    }


    /// Shortens the recorded device tree extent until no other reserved block
    /// reaches into it.
    ///
    /// The sweep's own clamp is one-sided. It moves the DTB's start up past
    /// whatever an earlier block already withheld, but a block sorted *after* the
    /// DTB may still start inside it, and the sweep is content to leave those
    /// frames with the DTB: for reserving they are withheld either way, so which
    /// block is credited never mattered. It matters here. Handing that overlap
    /// back would free the first pages of the initrd, and `ImageSharing` may
    /// already have those pages mapped read-only into one or more running
    /// address spaces: freeing them is live user memory corruption, not a stale
    /// future read, while the sweep's own accounting still called them reserved.
    ///
    /// A block starting at or below the extent's start collapses it to empty,
    /// which `reclaimDeviceTree` reads as nothing to do. The assignment only ever
    /// lowers `deviceTreeEnd`, so the order the blocks are visited in cannot undo
    /// an earlier trim.
    private mutating func trimDeviceTreeExtent(
        against reserved: InlineArray<3, ReservedRange>
    ) {
        for i in 0..<reserved.count {
            guard deviceTreeEnd > deviceTreeStart else { return }

            let block = reserved[i]
            guard !block.isDeviceTree, !block.isEmpty else { continue }
            guard block.end > deviceTreeStart, block.start < deviceTreeEnd else { continue }

            deviceTreeEnd = max(block.start, deviceTreeStart)
        }
    }


    /// `address` raised to the next multiple of `alignment`, which is how each
    /// bookkeeping region's start is derived from the previous one's end.
    ///
    /// The mask needs `alignment` to be a power of two, which every
    /// `MemoryLayout.alignment` is, and the only caller passes one of those. The
    /// rounding add is checked for the same reason `BuddyAllocator.alignUp` checks
    /// its own: an address near the top of the space wraps to a low one, and a
    /// bookkeeping arena placed there would be handed out as free frames.
    ///
    /// Both are preconditions rather than thrown errors because neither can be a
    /// property of the machine. The alignment is a compile-time layout constant and
    /// the address comes from a linker symbol, so a failure is a bug in the lines
    /// above and not a boot this kernel could continue.
    private static func alignUp(
        _ address   : UInt64,
        to alignment: Int
    ) -> UInt64 {
        precondition(
            alignment > 0 && alignment & (alignment - 1) == 0,
            "bookkeeping alignment is not a power of two"
        )

        let step               = UInt64(alignment)
        let (raised, overflow) = address.addingReportingOverflow(step - 1)

        precondition(
            !overflow,
            "bookkeeping arena rounds past the top of the address space"
        )

        return raised & ~(step - 1)
    }
}


// MARK: - Host test seam

/// Doors into the boot-time bookkeeping that exist for the host suites only, gated
/// exactly like `UserMemory.validationOverride`: `hasFeature(Embedded)` is on only
/// when `Package.swift` sees `FREESTANDING=1`, so none of this is compiled into the
/// bare-metal image and the machine cannot reach it even by mistake.
///
/// The machine builds this type through `init()`, which reads `Kernel.platformInfo`,
/// the linker symbols and a live MMU, none of which a host process has. Everything
/// that initializer records on the way is `private`: the allocator, the RAM bounds
/// and the device tree extent. A host test could therefore only stand up a manager
/// with a null allocator and no extent, which is the limit `HostRAM` documents when
/// it forbids `alloc`. These four declarations are what open the allocation and
/// reclaim paths to a test, and nothing else about the type had to change.
#if !hasFeature(Embedded)
extension PhysicalPageManager {

    /// A manager over a caller-owned arena, with a working allocator behind it.
    ///
    /// `allocatedPages` starts at the extent's page count, which is what the boot
    /// sweep leaves behind for a withheld block: `reclaimDeviceTree` subtracts
    /// exactly that on its way out, and a manager that never counted those frames
    /// would wrap the counter instead of returning it to zero.
    ///
    /// A `deviceTree` extent has to be a range the caller already withheld, page
    /// aligned, inside the arena and with every frame in it marked `.reserved`:
    /// mark first, install second (`HostRAM.markReserved`). The checks below are
    /// preconditions and not refusals because an extent that fails one is a bug in
    /// the caller, and the failure it would otherwise produce is a reclaim donating
    /// frames the allocator already owns, which is a corrupted free list several
    /// calls later.
    init(
        hostAllocator : A,
        ramStart      : PhysicalAddress,
        ramSize       : UInt64,
        framesMetadata: UnsafeMutablePointer<FrameInfo>?,
        deviceTree    : (start: PhysicalAddress, end: PhysicalAddress)? = nil
    ) {
        if let given = deviceTree {
            precondition(
                given.start < given.end,
                "device tree extent is empty: pass nil for a manager with no extent"
            )
            precondition(
                given.start >= ramStart && given.end <= ramStart + ramSize,
                "device tree extent lies outside the arena it is recorded against"
            )
            precondition(
                given.start % 4096 == 0 && given.end % 4096 == 0,
                "device tree extent is not page aligned"
            )

            // Skipped when there is no array to read, which is the shape the
            // metadata-refusal path is built to exercise.
            if let metadata = framesMetadata {
                var address = given.start
                while address < given.end {
                    precondition(
                        metadata[Int((address - ramStart) / 4096)].flags.contains(.reserved),
                        "device tree extent covers a frame nobody withheld: mark the range reserved first"
                    )
                    address += 4096
                }
            }
        }

        let extent = deviceTree ?? (start: 0, end: 0)

        self.allocator       = hostAllocator
        self.ramStart        = ramStart
        self.ramSize         = ramSize
        self.framesMetadata  = framesMetadata

        self.totalPages      = ramSize / 4096
        self.allocatedPages  = extent.end > extent.start
                             ? (extent.end - extent.start) / 4096
                             : 0

        self.deviceTreeStart = extent.start
        self.deviceTreeEnd   = extent.end
    }


    /// The extent `reclaimDeviceTree` would hand back, which is the only observable
    /// a trim has: the sweep records it and the reclaim zeroes it.
    var deviceTreeExtent: (start: PhysicalAddress, end: PhysicalAddress) {
        (deviceTreeStart, deviceTreeEnd)
    }


    /// `clearRangeMetadata` under a name a test can reach, so the all-zero
    /// `FrameInfo` it promises can be asserted against the real array.
    func clearMetadata(
        from: PhysicalAddress,
        to  : PhysicalAddress
    ) {
        clearRangeMetadata(from: from, to: to)
    }
}


extension PhysicalPageManager where A == BuddyAllocator {

    /// `trimDeviceTreeExtent` over the blocks a test names.
    ///
    /// It takes plain address pairs because `ReservedRange` is private to this file,
    /// so no test can build the `InlineArray<3, ReservedRange>` the real signature
    /// wants. The blocks are the *other* reserved ranges, the kernel image and the
    /// initrd, so none of them carries the device tree flag: a block that does is
    /// the one the trim skips.
    ///
    /// Three is the sweep's own count. A shorter list is padded with empty ranges,
    /// which the trim skips exactly as it skips a boot block that fell outside RAM.
    mutating func trimDeviceTreeExtent(
        againstBlocks blocks: [(start: PhysicalAddress, end: PhysicalAddress)]
    ) {
        let ramEnd = ramStart + ramSize

        var reserved = InlineArray<3, ReservedRange>(repeating: ReservedRange(
            from   : ramStart,
            to     : ramStart,
            ramLow : ramStart,
            ramHigh: ramEnd
        ))

        for index in 0..<min(blocks.count, reserved.count) {
            reserved[index] = ReservedRange(
                from   : blocks[index].start,
                to     : blocks[index].end,
                ramLow : ramStart,
                ramHigh: ramEnd
            )
        }

        trimDeviceTreeExtent(against: reserved)
    }
}
#endif
