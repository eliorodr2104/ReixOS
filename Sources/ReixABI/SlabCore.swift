//
//  SlabCore.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

/// Power-of-two slab allocator shared by the kernel heap (`PPMBackend`) and the
/// userland heap (`SbrkBackend`). The backend owns pages and block liveness;
/// the core owns which free block goes out next.
///
/// Allocation and free are constant time in the number of free blocks and of
/// pages, because nothing is ever walked:
///
/// - each class keeps a doubly linked list of its partial pages, the ones with
///   a free block to give. A page leaves it when it fills, and leaves it and goes
///   back to the backend the moment it empties, by unlinking itself.
/// - a small-class page (below `largeShift`) keeps in its reserved blocks the
///   liveness bitmap, its list links, the head of its own free list and a bump
///   index. Blocks at or past the bump were never handed out, so a new page is
///   used as is instead of being threaded block by block.
/// - a large-class page has at most sixteen blocks, and the backend's liveness
///   word is its whole free set. Its links live in its highest free block, which
///   exists exactly while the page is on the list, so these classes reserve
///   nothing.
///
/// Shift, block index and count arithmetic wraps rather than traps. Every such
/// value is bounded by one page (shift 3...12, index below 512) where it enters,
/// through `alloc`'s size check or `location`, so a trap on each would only add
/// code to every program the core is compiled into.
///
/// A free block's bytes can be rewritten after its free. Every link read from a
/// page is checked against the backend before it is followed or written, so a
/// corrupted one costs the blocks it orphans and nothing else: it never leads
/// into memory the class does not own or onto a live block.
public struct SlabCore<Backend: SlabBackend> {

    public static var pageSize: Int   { 4096 }
    public static var minShift: UInt8 { 3    } // 8B small block

    /// First class whose pages hold at most sixteen blocks, the width of the
    /// backends' liveness word. Classes below it keep an in-page bitmap instead.
    public static var largeShift: UInt8 { 8 }

    public var backend: Backend

    /// Pages this core currently holds from its backend.
    ///
    /// This is allocator backing, not live payload: one page remains reserved
    /// while any block carved from it is live. The wrapper may combine it with
    /// backing for allocations larger than one page.
    public private(set) var reservedPages: UInt = 0

    /// Head of each class's partial-page list, indexed by `shift - minShift`.
    ///
    /// A head is always a page of its class with a free block, corrupted links
    /// or not: a link enters only through `listed`, and every change that leaves
    /// a page without a free block, or releases it, unlinks it first.
    private var partial = InlineArray<10, UnsafeMutableRawPointer?>(repeating: nil)

    public init(backend: Backend) { self.backend = backend }

    // size must be in (0, 4096]; the wrapper routes anything larger to mmap.
    public mutating func alloc(size: UInt) -> UnsafeMutableRawPointer? {
        guard size != 0, size <= UInt(Self.pageSize) else { return nil }

        let rounded = roundUpPow2(size)
        guard rounded != 0 else { return nil }

        var shift = UInt8(rounded.trailingZeroBitCount)

        if shift < Self.minShift { shift = Self.minShift }

        let i = Int(shift &- Self.minShift)
        if let page = partial[i] { return take(from: page, shift: shift, index: i) }
        return carve(shift: shift, index: i)
    }

    /// Returns `false` unless `ptr` is the start of a currently live block on a
    /// page owned by this backend. Rejected pointers never touch any list.
    @discardableResult
    public mutating func free(_ ptr: UnsafeMutableRawPointer) -> Bool {
        freeCapacity(ptr) != nil
    }

    /// Frees a validated live block and returns its rounded capacity.
    /// The location/liveness lookup is shared with the transition so wrappers
    /// can account a free without repeating the hot-path metadata walk.
    @discardableResult
    public mutating func freeCapacity(_ ptr: UnsafeMutableRawPointer) -> UInt? {
        guard let location = location(of: ptr) else { return nil }

        let page   = location.page
        let shift  = location.shift
        let result = backend.onFreeBlock(
            page      : page,
            blockIndex: location.blockIndex,
            shift     : shift
        )
        guard result != .invalid else { return nil }

        let i = Int(shift &- Self.minShift)

        if shift < Self.largeShift {
            let header = Self.header(of: page, shift: shift)
            let head   = header.load(fromByteOffset: Self.freeHeadOffset, as: UInt16.self)
            let listed = head != 0 || header.load(fromByteOffset: Self.bumpOffset, as: UInt16.self)
                                        < UInt16(truncatingIfNeeded: Self.pageSize >> Int(shift))

            if result == .releasePage {
                if listed { unlink(page, shift: shift, index: i, linksAt: header) }
                release(page)
            } else {
                slabStore(head, at: ptr)
                slabStore(UInt16(truncatingIfNeeded: location.blockIndex), at: header + Self.freeHeadOffset)
                if !listed { push(page, shift: shift, index: i, linksAt: header) }
            }

            return UInt(1) << UInt(shift)
        }

        // The free set as it was before this block joined it, which is where the
        // page's links were while it was on the list.
        let before = freeMask(of: page, shift: shift) & ~(UInt16(1) &<< UInt16(truncatingIfNeeded: location.blockIndex))

        if result == .releasePage {
            if before != 0 {
                unlink(page, shift: shift, index: i, linksAt: Self.linkSlot(page, shift: shift, free: before))
            }
            release(page)
        } else if before == 0 {
            push(page, shift: shift, index: i, linksAt: ptr)
        } else if location.blockIndex > Self.highest(before) {
            // The links follow the highest free block, which is now this one.
            let old = Self.linkSlot(page, shift: shift, free: before)
            slabStore(old.load(fromByteOffset: Self.prevOffset, as: UnsafeMutableRawPointer?.self), at: ptr + Self.prevOffset)
            slabStore(old.load(fromByteOffset: Self.nextOffset, as: UnsafeMutableRawPointer?.self), at: ptr + Self.nextOffset)
        }

        return UInt(1) << UInt(shift)
    }

    /// Size of the bucket that owns `ptr`, only while that exact block is live.
    /// The kernel typed-free wrapper uses this before it invokes any destructor.
    /// Works on a copy so it can stay non-mutating: only the kernel calls it, and
    /// `PPMBackend` is one pointer wide.
    public func allocationSize(of ptr: UnsafeMutableRawPointer) -> UInt? {
        var core = self
        guard let location = core.location(of: ptr) else { return nil }

        let live = location.shift < Self.largeShift
            ? slabPageBitIsSet(page: location.page, blockIndex: location.blockIndex)
            : core.backend.largeLiveBits(ofPage: location.page)
                  & (UInt16(1) &<< UInt16(truncatingIfNeeded: location.blockIndex)) != 0
        guard live else { return nil }

        return UInt(1) << UInt(location.shift)
    }


    // MARK: - internals

    @inline(__always)
    public static func pageBase(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: p) & ~UInt(0xFFF))!
    }

    /// Blocks a small-class page keeps for itself: its liveness bitmap and the
    /// header after it, rounded up to whole blocks so none of the allocator's
    /// private state can be handed to a caller. Large classes reserve nothing.
    @inline(__always)
    public static func reservedBlockCount(forShift shift: UInt8) -> Int {
        guard shift >= Self.minShift, shift < Self.largeShift else { return 0 }

        let blockSize = 1 << Int(shift)
        return (bitmapBytes(forShift: shift) &+ headerBytes &+ blockSize &- 1) >> Int(shift)
    }

    /// One bit per block in whole 64-bit words, as `slabPageBitIsSet` reads it.
    @inline(__always)
    static func bitmapBytes(forShift shift: UInt8) -> Int {
        (((Self.pageSize >> Int(shift)) &+ 63) >> 6) << 3
    }

    // The two list links come first, so a small-class header and a large-class
    // link slot share one layout. Free-list head 0 is empty: block 0 is reserved.
    static var prevOffset    : Int { 0  }
    static var nextOffset    : Int { 8  }
    static var freeHeadOffset: Int { 16 }
    static var bumpOffset    : Int { 18 }
    static var headerBytes   : Int { 20 }

    @inline(__always)
    static func header(
        of page: UnsafeMutableRawPointer,
        shift  : UInt8
    ) -> UnsafeMutableRawPointer {
        page + bitmapBytes(forShift: shift)
    }

    /// Where a large-class page with free set `free` keeps its links: its
    /// highest free block. `free` must not be empty.
    @inline(__always)
    static func linkSlot(
        _ page: UnsafeMutableRawPointer,
        shift : UInt8,
        free  : UInt16
    ) -> UnsafeMutableRawPointer {
        page + (highest(free) << Int(shift))
    }

    @inline(__always)
    static func highest(_ mask: UInt16) -> Int {
        15 &- mask.leadingZeroBitCount
    }

    /// Free blocks of a large-class page, one bit per block.
    @inline(__always)
    mutating func freeMask(
        of page: UnsafeMutableRawPointer,
        shift  : UInt8
    ) -> UInt16 {
        let blocks = Self.pageSize >> Int(shift)
        return ~backend.largeLiveBits(ofPage: page) & (UInt16.max >> UInt16(truncatingIfNeeded: 16 &- blocks))
    }

    /// Hands out one block of `page`, the head of class `i`'s list, and takes the
    /// page off the list when that was the last free block it could reach.
    private mutating func take(
        from page: UnsafeMutableRawPointer,
        shift    : UInt8,
        index i  : Int
    ) -> UnsafeMutableRawPointer? {
        if shift >= Self.largeShift {
            let free  = freeMask(of: page, shift: shift)
            let block = free.trailingZeroBitCount
            let slot  = page + (block << Int(shift))
            let last  = free & (free &- 1) == 0

            // The last free block is also the link slot: read it before it goes.
            let prev = last ? slot.load(fromByteOffset: Self.prevOffset, as: UnsafeMutableRawPointer?.self) : nil
            let next = last ? slot.load(fromByteOffset: Self.nextOffset, as: UnsafeMutableRawPointer?.self) : nil

            guard backend.onAllocBlock(page: page, blockIndex: block, shift: shift) else { return nil }

            if last { unlink(page, shift: shift, index: i, prev: prev, next: next) }
            return slot
        }

        let header   = Self.header(of: page, shift: shift)
        let blocks   = UInt16(truncatingIfNeeded: Self.pageSize >> Int(shift))
        let reserved = UInt16(truncatingIfNeeded: Self.reservedBlockCount(forShift: shift))
        var head     = header.load(fromByteOffset: Self.freeHeadOffset, as: UInt16.self)
        var bump     = header.load(fromByteOffset: Self.bumpOffset,     as: UInt16.self)
        let block    : UInt16

        if head != 0 {
            guard head >= reserved, head < bump,
                  !slabPageBitIsSet(page: page, blockIndex: Int(head))
            else {
                // The head was rewritten after its free. Drop this page's list and
                // fail closed: its nodes stay free in the bitmap but unreachable.
                slabStore(UInt16(0), at: header + Self.freeHeadOffset)
                if bump == blocks { unlink(page, shift: shift, index: i, linksAt: header) }
                return nil
            }

            block = head
            let next = (page + (Int(head) << Int(shift))).load(as: UInt16.self)
            head = next >= reserved && next < bump ? next : 0
        } else {
            block = bump
            bump &+= 1
        }

        guard backend.onAllocBlock(page: page, blockIndex: Int(block), shift: shift) else { return nil }

        slabStore(head, at: header + Self.freeHeadOffset)
        slabStore(bump, at: header + Self.bumpOffset)
        if head == 0 && bump == blocks { unlink(page, shift: shift, index: i, linksAt: header) }

        return page + (Int(block) << Int(shift))
    }

    /// A fresh page goes on the list empty and its first block comes out through
    /// `take`, so the hand-out and the backend transition exist once, not twice.
    private mutating func carve(shift: UInt8, index i: Int) -> UnsafeMutableRawPointer? {
        guard let page = backend.acquirePage() else { return nil }

        // Account the backing as soon as ownership transfers. If initialization
        // then fails and the backend cannot release it, the retained page stays
        // visible instead of disappearing from the metric.
        reservedPages += 1
        
        backend.bind(page: page, shift: shift)
        let links: UnsafeMutableRawPointer

        if shift < Self.largeShift {
            links = Self.header(of: page, shift: shift)
            for word in 0..<Self.bitmapBytes(forShift: shift) / 8 {
                slabStore(UInt64(0), at: page + word * 8)
            }
            slabStore(UInt16(0), at: links + Self.freeHeadOffset)
            slabStore(UInt16(truncatingIfNeeded: Self.reservedBlockCount(forShift: shift)), at: links + Self.bumpOffset)
        } else {
            links = page + ((Self.pageSize >> Int(shift) &- 1) << Int(shift))
        }

        push(page, shift: shift, index: i, linksAt: links)
        if let block = take(from: page, shift: shift, index: i) { return block }

        unlink(page, shift: shift, index: i, linksAt: links)
        release(page)
        return nil
    }

    private mutating func release(_ page: UnsafeMutableRawPointer) {
        if backend.releasePage(page) {
            precondition(reservedPages > 0, "slab reserved-page accounting underflow")
            reservedPages -= 1
        }
    }

    /// Puts `page`, whose link slot is `links`, at the head of class `i`'s list.
    /// The head needs no `listed` check: it is the core's own state, not a link
    /// read from a page, and `page` is not on the list yet so it cannot be it.
    private mutating func push(
        _ page        : UnsafeMutableRawPointer,
        shift         : UInt8,
        index i       : Int,
        linksAt links : UnsafeMutableRawPointer
    ) {
        let head = partial[i]

        slabStore(UnsafeMutableRawPointer?.none, at: links + Self.prevOffset)
        slabStore(head,                          at: links + Self.nextOffset)
        if let head { storeLink(page, into: head, at: Self.prevOffset, shift: shift) }
        partial[i] = page
    }

    private mutating func unlink(
        _ page        : UnsafeMutableRawPointer,
        shift         : UInt8,
        index i       : Int,
        linksAt links : UnsafeMutableRawPointer
    ) {
        unlink(
            page,
            shift: shift,
            index: i,
            prev : links.load(fromByteOffset: Self.prevOffset, as: UnsafeMutableRawPointer?.self),
            next : links.load(fromByteOffset: Self.nextOffset, as: UnsafeMutableRawPointer?.self)
        )
    }

    /// Takes `page` off class `i`'s list in O(1). A neighbour that fails the
    /// check in `listed` is treated as the end of the list and never written.
    @inline(never)
    private mutating func unlink(
        _ page : UnsafeMutableRawPointer,
        shift  : UInt8,
        index i: Int,
        prev   : UnsafeMutableRawPointer?,
        next   : UnsafeMutableRawPointer?
    ) {
        let prev = listed(prev, shift: shift, other: page)
        let next = listed(next, shift: shift, other: page)

        if partial[i] == page { partial[i] = next }
        if let prev { storeLink(next, into: prev, at: Self.nextOffset, shift: shift) }
        if let next { storeLink(prev, into: next, at: Self.prevOffset, shift: shift) }
    }

    /// `link` when it names a page of this class, other than `page`, that has a
    /// free block and so a link slot; nil otherwise. The only door a link read
    /// from page memory goes through before anything follows it.
    @inline(never)
    private mutating func listed(
        _ link: UnsafeMutableRawPointer?,
        shift : UInt8,
        other page: UnsafeMutableRawPointer
    ) -> UnsafeMutableRawPointer? {
        guard let link, link != page,
              UInt(bitPattern: link) & UInt(Self.pageSize - 1) == 0,
              isListable(link, shift: shift)
        else { return nil }

        return link
    }

    /// Whether `page` is a page of class `shift` with a free block it can reach.
    @inline(__always)
    private mutating func isListable(
        _ page: UnsafeMutableRawPointer,
        shift : UInt8
    ) -> Bool {
        guard backend.shiftIfOwned(ofPage: page) == shift else { return false }

        if shift >= Self.largeShift { return freeMask(of: page, shift: shift) != 0 }

        let header = Self.header(of: page, shift: shift)
        return header.load(fromByteOffset: Self.freeHeadOffset, as: UInt16.self) != 0
            || header.load(fromByteOffset: Self.bumpOffset, as: UInt16.self)
                   < UInt16(truncatingIfNeeded: Self.pageSize >> Int(shift))
    }

    /// Writes one link of a page `listed` has accepted.
    @inline(__always)
    private mutating func storeLink(
        _ value : UnsafeMutableRawPointer?,
        into page: UnsafeMutableRawPointer,
        at offset: Int,
        shift    : UInt8
    ) {
        let slot = shift < Self.largeShift
            ? Self.header(of: page, shift: shift)
            : Self.linkSlot(page, shift: shift, free: freeMask(of: page, shift: shift))
        slabStore(value, at: slot + offset)
    }

    private struct BlockLocation {
        let page      : UnsafeMutableRawPointer
        let shift     : UInt8
        let blockIndex: Int
    }

    @inline(__always)
    private mutating func location(of ptr: UnsafeMutableRawPointer) -> BlockLocation? {
        let address = UInt(bitPattern: ptr)
        let pageAddress = address & ~UInt(0xFFF)
        guard pageAddress != 0,
              let page = UnsafeMutableRawPointer(bitPattern: pageAddress),
              let shift = backend.shiftIfOwned(ofPage: page)
        else { return nil }

        guard shift >= Self.minShift,
              shift <= UInt8(Self.pageSize.trailingZeroBitCount)
        else { return nil }

        let blockSize = UInt(1) << UInt(shift)
        let offset = address &- pageAddress
        guard (offset & (blockSize &- 1)) == 0 else { return nil }

        let blockIndex = Int(truncatingIfNeeded: offset >> UInt(shift))
        guard blockIndex >= Self.reservedBlockCount(forShift: shift),
              blockIndex < Self.pageSize >> Int(shift)
        else { return nil }

        return BlockLocation(page: page, shift: shift, blockIndex: blockIndex)
    }
}


// MARK: - Host test seam

#if !hasFeature(Embedded)
/// One slab page's list state, copied out for the host invariant checker.
public struct SlabPageState {
    public let prev: UnsafeMutableRawPointer?
    public let next: UnsafeMutableRawPointer?

    /// Small classes: the page's free list from its head, cut at one page's
    /// worth of nodes so a cycle ends. Large classes: the free blocks, ascending.
    public let freeBlocks: [Int]

    /// First block never handed out; the block count for a large class.
    public let bump: Int
}

extension SlabCore {

    /// Class `shift`'s partial list from its head along `next`, stopping at the
    /// first page with no link slot or after `limit` pages.
    public func partialPages(
        shift: UInt8,
        limit: Int = 1 << 16
    ) -> [UnsafeMutableRawPointer] {
        var core = self
        var pages: [UnsafeMutableRawPointer] = []
        var current = partial[Int(shift - Self.minShift)]

        while let page = current, pages.count < limit, core.isListable(page, shift: shift) {
            pages.append(page)
            current = pageState(page, shift: shift).next
        }
        return pages
    }

    public func pageState(
        _ page: UnsafeMutableRawPointer,
        shift : UInt8
    ) -> SlabPageState {
        var core   = self
        let blocks = Self.pageSize >> Int(shift)

        if shift >= Self.largeShift {
            let free  = core.freeMask(of: page, shift: shift)
            let slot  = free == 0 ? nil : Self.linkSlot(page, shift: shift, free: free)
            return SlabPageState(
                prev      : slot?.load(fromByteOffset: Self.prevOffset, as: UnsafeMutableRawPointer?.self),
                next      : slot?.load(fromByteOffset: Self.nextOffset, as: UnsafeMutableRawPointer?.self),
                freeBlocks: (0..<blocks).filter { free & (UInt16(1) << UInt16($0)) != 0 },
                bump      : blocks
            )
        }

        let header = Self.header(of: page, shift: shift)
        var nodes: [Int] = []
        var node = Int(header.load(fromByteOffset: Self.freeHeadOffset, as: UInt16.self))
        while node != 0, node < blocks, nodes.count < blocks {
            nodes.append(node)
            node = Int((page + (node << Int(shift))).load(as: UInt16.self))
        }

        return SlabPageState(
            prev      : header.load(fromByteOffset: Self.prevOffset, as: UnsafeMutableRawPointer?.self),
            next      : header.load(fromByteOffset: Self.nextOffset, as: UnsafeMutableRawPointer?.self),
            freeBlocks: nodes,
            bump      : Int(header.load(fromByteOffset: Self.bumpOffset, as: UInt16.self))
        )
    }
}
#endif
