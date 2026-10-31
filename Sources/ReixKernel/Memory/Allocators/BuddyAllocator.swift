//
//  BuddyAllocator.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

/// Binary buddy allocator over one contiguous span of RAM.
///
/// State is kept per free block and not per page, so alloc, free, split and
/// coalesce cost a bounded number of steps per order instead of one per page:
///
/// - `freeHeads` has one bit per frame, set exactly when that frame is the
///   head of a free block;
/// - that block's order is in the `FreeBlock` node overlaid on its first bytes,
///   which is read only after the bit says the block is free, so it is always
///   memory this allocator owns and never bytes an owner wrote;
/// - the block is linked on `freeLists[order]`.
///
/// The three agree at every return: a bit is set if and only if its frame heads
/// a block on the list its node names, free blocks never overlap, and no two
/// free blocks of the same order are buddies (they would have merged). "Is my
/// buddy a free block of exactly this order?" is one bit and one byte.
public struct BuddyAllocator: Allocator {

    private let startRam       : PhysicalAddress
    private let sizeRam        : UInt64

    /// One bit per frame, set on the head of every free block and nowhere else.
    ///
    /// Same size as the per-page allocation bitmap it replaces, so the boot
    /// arena in `PhysicalPageManager.init` did not move. Zero is "no free block
    /// starts here", which is also what a frame never donated reads as.
    private let freeHeads      : UnsafeMutablePointer<UInt8>

    /// One free list per order (0...maxOrder), kept in the boot bookkeeping arena.
    /// The list nodes live inside the free blocks (`FreeBlock`), so this only
    /// stores the 12 list heads/tails, the heavy data is in the pages.
    ///
    /// 192 bytes, which is why `PhysicalPageManager.init` packs the table into a
    /// page it already owns rather than rounding one up for it. See `freeListsBytes`.
    private let freeLists      : UnsafeMutablePointer<LinkedList<FreeBlock>>

    private static let pageSize: UInt64 = 4096

    /// Raisable to 14 and no further: `FrameInfo` packs `order` into a nibble and
    /// 15 is `PhysicalPageManager.blockInteriorOrder`. A larger value is silently
    /// truncated there, and 15 would alias that sentinel, so a block head would
    /// read back as a block interior.
    private static let maxOrder: UInt8  = 11


    /// Bytes the free-list table needs, one `LinkedList<FreeBlock>` per order.
    ///
    /// Published because `PhysicalPageManager.init` reserves the region this
    /// initializer then zeroes, and the two now sit byte to byte with the bitmap in
    /// a shared page: a `maxOrder` raised here without the reservation following
    /// would have the memset below run into a frame the buddy hands out. Both read
    /// this, so there is one number to raise.
    public static var freeListsBytes: Int {
        (Int(maxOrder) + 1) * MemoryLayout<LinkedList<FreeBlock>>.stride
    }

    public init(
        start           : PhysicalAddress,
        size            : UInt64,
        bitmapAddress   : PhysicalAddress,
        freeListsAddress: PhysicalAddress
    ) {
        self.startRam   = start
        self.sizeRam    = size
        let totalPages  = size / UInt64(Self.pageSize)
        let bitmapBytes = Int((totalPages + 7) / 8)

        self.freeHeads = UnsafeMutablePointer<UInt8>(bitPattern: UInt(bitmapAddress))!
        self.freeLists = UnsafeMutablePointer<LinkedList<FreeBlock>>(bitPattern: UInt(freeListsAddress))!

        UnsafeMutableRawPointer(freeLists).initializeMemory(as: UInt8.self, repeating: 0, count: Self.freeListsBytes)

        freeHeads.initialize(repeating: 0, count: bitmapBytes)
    }


    /// Takes the smallest non-empty order that fits and splits it down, pushing
    /// each upper half on its own list: at most `maxOrder` steps either way.
    public func alloc(_ bytes: Int) throws(AllocatorError) -> PhysicalPage {
        guard bytes >= 0, bytes <= Int(Self.pageSize << UInt64(Self.maxOrder)) else {
            throw .bytesNotValid(bytes)
        }

        let pages       = (bytes + Int(Self.pageSize) - 1) / Int(Self.pageSize)
        let targetOrder = pages <= 1 ? 0 : UInt8(Int.bitWidth - (pages - 1).leadingZeroBitCount)

        var order = targetOrder
        while (freeLists + Int(order)).pointee.head == nil {
            guard order < Self.maxOrder else { throw .fullMemory }
            order += 1
        }

        let offset = popFreeBlock(order: order)

        while order > targetOrder {
            order -= 1
            pushFreeBlock(offset: offset + (Self.pageSize << UInt64(order)), order: order)
        }

        return PhysicalPage(address: startRam + offset, order: targetOrder)
    }


    /// Refuses a block that is not one, or that is already free in whole or in
    /// part, before anything is written; then merges upward while the buddy is
    /// a free block of exactly the current order.
    ///
    /// "In part" means its first frame lies in a free block. A free block nested
    /// further inside is reachable only by naming the wrong order, which
    /// `PhysicalPageManager` refuses first against the order it recorded.
    public func free(_ page: consuming PhysicalPage) throws(AllocatorError) {
        guard try isValidBlock(address: page.address, order: page.order) else {
            throw .addressInvalid(page.address)
        }

        let offset = page.address - startRam
        guard !liesInFreeBlock(offset: offset) else { throw .doubleFreeInvalid }

        mergeAndInsert(offset: offset, order: page.order)
    }


    /// Donates `rawStart ..< rawEnd`, page-aligned inward, as the largest aligned
    /// blocks that fit. A donation overlapping memory that is already free is
    /// refused whole before the first block goes in: a free block either covers
    /// the first frame or starts inside the range, and has a head bit there.
    public func addFreeRange(
        from rawStart: PhysicalAddress,
        to   rawEnd  : PhysicalAddress
    ) throws(AllocatorError) {

        let ramEnd = try getRamEnd(address: rawStart)

        guard rawStart >= startRam &&
              rawStart < ramEnd    &&
              rawEnd   <= ramEnd else { throw .addressInvalid(rawStart) }

        guard rawStart < rawEnd else {
            throw .addressRangeInvalid(
                from: rawStart,
                to  : rawEnd
            )
        }

        let start = try alignUp(max(rawStart, startRam), Self.pageSize) - startRam
        let end   = alignDown(min(rawEnd, ramEnd), Self.pageSize) - startRam

        guard start < end else { return }

        guard !liesInFreeBlock(offset: start),
              !anyFreeHead(from: start, to: end)
        else { throw .doubleFreeInvalid }

        var current = start
        while current < end {
            let order = largestOrder(at: current, before: end)

            mergeAndInsert(offset: current, order: order)
            current += Self.pageSize << UInt64(order)
        }
    }


    // MARK: - Helpers

    /// Inserts a block already validated by the caller, merging it with its
    /// buddy at each order for as long as the buddy is free at exactly that
    /// order. A free head of order k always fits in RAM, so a buddy that would
    /// run past the end can never pass that test.
    private func mergeAndInsert(
        offset: UInt64,
        order : UInt8
    ) {
        var currentOffset = offset
        var currentOrder  = order

        while currentOrder < Self.maxOrder {
            let blockBytes  = Self.pageSize << UInt64(currentOrder)
            let buddyOffset = currentOffset ^ blockBytes

            guard buddyOffset < sizeRam,
                  isFreeBlock(offset: buddyOffset, order: currentOrder)
            else { break }

            unlinkFreeBlock(offset: buddyOffset, order: currentOrder)

            currentOffset = min(currentOffset, buddyOffset)
            currentOrder += 1
        }

        pushFreeBlock(offset: currentOffset, order: currentOrder)
    }


    /// Largest order whose block starts aligned at `offset` and ends by `end`.
    @inline(__always)
    private func largestOrder(
        at offset : UInt64,
        before end: UInt64
    ) -> UInt8 {
        let page      = offset / Self.pageSize
        let aligned   = page == 0 ? Self.maxOrder : UInt8(min(page.trailingZeroBitCount, Int(Self.maxOrder)))
        let remaining = (end - offset) / Self.pageSize
        let fits      = UInt8(UInt64.bitWidth - 1 - remaining.leadingZeroBitCount)

        return min(aligned, fits)
    }


    /// Whether the frame at `offset` belongs to any free block. A covering block
    /// of order k starts at `offset` rounded down to k, so one probe per order
    /// finds it.
    private func liesInFreeBlock(offset: UInt64) -> Bool {
        for order in 0...Self.maxOrder {
            let head = offset & ~((Self.pageSize << UInt64(order)) - 1)

            if isFreeBlock(offset: head, order: order) { return true }
        }

        return false
    }


    /// One byte per eight frames where the range allows it. Linear in the range,
    /// which only donation pays: boot and the device tree reclaim, once each.
    private func anyFreeHead(
        from start: UInt64,
        to   end  : UInt64
    ) -> Bool {
        var page = Int(start / Self.pageSize)
        let last = Int(end / Self.pageSize)

        while page < last {
            if page & 7 == 0, last - page >= 8 {
                if freeHeads[page >> 3] != 0 { return true }
                page += 8
            } else {
                if freeHeads[page >> 3] & (1 << UInt8(page & 7)) != 0 { return true }
                page += 1
            }
        }

        return false
    }


    @inline(__always)
    private func isFreeBlock(
        offset: UInt64,
        order : UInt8
    ) -> Bool {
        isFreeHead(offset: offset) && node(at: offset).pointee.order == order
    }


    @inline(__always)
    private func isFreeHead(offset: UInt64) -> Bool {
        let page = Int(offset / Self.pageSize)
        return freeHeads[page >> 3] & (1 << UInt8(page & 7)) != 0
    }


    @inline(__always)
    private func setFreeHead(
        offset: UInt64,
        _ free: Bool
    ) {
        let page = Int(offset / Self.pageSize)
        let bit  = UInt8(1) << UInt8(page & 7)

        if free {
            freeHeads[page >> 3] |= bit
        } else {
            freeHeads[page >> 3] &= ~bit
        }
    }


    @inline(__always)
    private func node(at offset: UInt64) -> UnsafeMutablePointer<FreeBlock> {
        UnsafeMutablePointer<FreeBlock>(bitPattern: UInt(startRam + offset))!
    }


    // `.pointee`, never the `freeLists[order]` subscript, in every free-list access:
    // the subscript copies the list in and out, an unaligned ldp with the MMU off.
    private func pushFreeBlock(
        offset: UInt64,
        order : UInt8
    ) {
        let block = node(at: offset)

        block.pointee.next  = nil
        block.pointee.prev  = nil
        block.pointee.order = order

        (freeLists + Int(order)).pointee.pushBack(block)
        setFreeHead(offset: offset, true)
    }


    /// Callers check the list is not empty first. The order is zeroed with the
    /// links, so a node leaves the lists as the all-zero bytes it had before.
    private func popFreeBlock(order: UInt8) -> UInt64 {
        let block  = (freeLists + Int(order)).pointee.popFront()!
        let offset = UInt64(UInt(bitPattern: block)) - startRam

        block.pointee.order = 0
        setFreeHead(offset: offset, false)
        return offset
    }


    /// Unlinks a block `isFreeBlock` just confirmed, so it is on exactly this
    /// list and the doubly linked `remove(element:)` splices it in O(1).
    private func unlinkFreeBlock(
        offset: UInt64,
        order : UInt8
    ) {
        let block = node(at: offset)

        (freeLists + Int(order)).pointee.remove(element: block)
        block.pointee.order = 0
        setFreeHead(offset: offset, false)
    }


    private func alignUp(
        _ x: UInt64,
        _ a: UInt64
    ) throws(AllocatorError) -> UInt64 {

        let remainder = x % a
        guard remainder != 0 else { return x }

        let increment = a - remainder
        let (result, overflow) = x.addingReportingOverflow(increment)
        guard !overflow else { throw .addressInvalid(x) }
        return result
    }

    private func alignDown(
        _ x: UInt64,
        _ a: UInt64
    ) -> UInt64 { x & ~(a - 1) }


    private func isValidBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) -> Bool {
        let ramEnd = try getRamEnd(address: address)

        guard address >= startRam &&
              address < ramEnd else { return false }

        guard order <= Self.maxOrder else {
            throw .pageOrderInvalid(order)
        }

        let blockBytes = Self.pageSize << UInt64(order)
        return (address - startRam) % blockBytes == 0 &&
                blockBytes <= ramEnd - address
    }

    private func getRamEnd(address: UInt64) throws(AllocatorError) -> UInt64 {
        let (ramEnd, overflow) = startRam.addingReportingOverflow(sizeRam)
        guard !overflow else { throw .addressInvalid(address) }

        return ramEnd
    }
}


// MARK: - Host test seam

#if !hasFeature(Embedded)
/// The allocator's private state, copied out for the host invariant checker.
/// Gated like the seam at the foot of `PhysicalPageManager.swift`, so the
/// machine is compiled without it.
struct BuddyFreeState {
    let start   : PhysicalAddress
    let size    : UInt64
    let maxOrder: UInt8

    /// Per list, each node walked from `head` along `next`, with the order its
    /// node records.
    let lists: [[(address: PhysicalAddress, order: UInt8)]]

    /// A `prev` that does not point back, a `tail` that is not the last node,
    /// or a walk longer than RAM has frames (a cycle). Zero when sound.
    let brokenLinks: Int

    /// Every frame whose head bit is set, ascending.
    let heads: [PhysicalAddress]
}


extension BuddyAllocator {

    var freeState: BuddyFreeState {
        let frames = Int(sizeRam / Self.pageSize)
        var lists : [[(address: PhysicalAddress, order: UInt8)]] = []
        var broken = 0

        for order in 0...Self.maxOrder {
            let list     = (freeLists + Int(order)).pointee
            var walked   : [(address: PhysicalAddress, order: UInt8)] = []
            var previous : UnsafeMutablePointer<FreeBlock>? = nil
            var current  = list.head

            while let block = current, walked.count <= frames {
                if block.pointee.prev != previous { broken += 1 }
                walked.append((UInt64(UInt(bitPattern: block)), block.pointee.order))
                previous = block
                current  = block.pointee.next
            }

            if current != nil || list.tail != previous { broken += 1 }
            lists.append(walked)
        }

        var heads: [PhysicalAddress] = []
        for page in 0..<frames where isFreeHead(offset: UInt64(page) * Self.pageSize) {
            heads.append(startRam + UInt64(page) * Self.pageSize)
        }

        return BuddyFreeState(
            start      : startRam,
            size       : sizeRam,
            maxOrder   : Self.maxOrder,
            lists      : lists,
            brokenLinks: broken,
            heads      : heads
        )
    }
}
#endif
