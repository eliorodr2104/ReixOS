//
//  BuddyAllocator.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

/// Intrusive free-list node overlaid on a free block's first 16 bytes.
///
/// The buddy free lists thread through the free blocks themselves (no extra
/// allocation — the allocator can't allocate to track its own free list), so
/// `FreeBlock` is materialised at a block's physical address and linked via a
/// `LinkedList<FreeBlock>`. Being doubly linked, unlinking an arbitrary buddy
/// during a merge is O(1). `entryID` is unused: the buddy never does id-based
/// lookups, only `pushBack`/`popFront`/`remove(element:)`.
public struct FreeBlock: RXEntry {
    public static var errorMessageAllocation: StaticString = "FreeBlock"
    public var prev: UnsafeMutablePointer<FreeBlock>?
    public var next: UnsafeMutablePointer<FreeBlock>?
    public var entryID: UInt64 { 0 }
}

public struct BuddyAllocator: Allocator {

    private let startRam       : PhysicalAddress
    private let sizeRam        : UInt64

    private let bitmap         : UnsafeMutablePointer<UInt8>

    /// One free list per order (0...maxOrder), kept in a small reserved region.
    /// The list nodes live inside the free blocks (`FreeBlock`), so this only
    /// stores the 12 list heads/tails — the heavy data is in the pages.
    private let freeLists      : UnsafeMutablePointer<LinkedList<FreeBlock>>

    private static let pageSize: UInt64 = 4096

    private static let maxOrder: UInt8  = 11

    
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
                
        self.bitmap    = UnsafeMutablePointer<UInt8>(bitPattern: UInt(bitmapAddress))!
        self.freeLists = UnsafeMutablePointer<LinkedList<FreeBlock>>(bitPattern: UInt(freeListsAddress))!

        // An empty LinkedList is all-zero (nil head/tail, count 0), so zero the
        // whole region from its page-aligned base. We must NOT `initialize(to:)`
        // each element: that memcpy's a 40-byte struct to 40-byte-strided (not
        // 16-aligned) offsets, and this runs with the MMU still off — where
        // memory is Device-typed and a 16-byte ldp/stp to a non-16-aligned
        // address faults. A memset from the aligned base is safe.
        let listsBytes = (Int(Self.maxOrder) + 1) * MemoryLayout<LinkedList<FreeBlock>>.stride
        UnsafeMutableRawPointer(freeLists).initializeMemory(as: UInt8.self, repeating: 0, count: listsBytes)

        bitmap.initialize(repeating: 0xFF, count: bitmapBytes)
    }
    
    
    public func alloc(_ bytes: Int) throws(AllocatorError) -> PhysicalPage {
        let bSize = try blockSize(Self.maxOrder)
        guard bytes >= 0, bytes <= bSize else { throw(.bytesNotValid(bytes)) }
        
        let pageSize    = Int(Self.pageSize)
        let maxPage     = (bytes + pageSize - 1) / pageSize
        var targetOrder: UInt8 = 0
        
        while(UInt64(1) << targetOrder) < maxPage {
            targetOrder += 1
        }
        
        for currentOrder in targetOrder...Self.maxOrder {
            let page = try getFreeListHead(order: currentOrder)
            
            if page != 0 {
                let _ = try popFreeBlock(order: currentOrder)
                
                if currentOrder > targetOrder {
                    var iterator = currentOrder
                    
                    while iterator > targetOrder {
                        iterator -= 1
                        
                        let dimSplitBuddy = try blockSize(iterator)
                        let buddyAddress  = page + dimSplitBuddy
                        
                        try pushFreeBlock(address: buddyAddress, order: iterator)
                        try clearBitmapRange(address: buddyAddress, order: iterator)
                    }
                                        
                }
                
                try setBitmapRange(address: page, order: targetOrder)
                return PhysicalPage(address: page, order: targetOrder)
            }
        }
        
        throw(.fullMemory)
    }
    
    public func free(_ page: consuming PhysicalPage) throws(AllocatorError) {
        guard (page.address >= startRam &&
                page.address <= startRam + sizeRam)
        else { throw .addressInvalid(page.address) }
        guard try !isBlockFree(page.address, order: page.order) else { throw(.doubleFreeInvalid) }


        try mergeAndInsert(address: page.address, order: page.order)
    }
    
    
    public func addFreeRange(
        from rawStart: PhysicalAddress,
        to   rawEnd  : PhysicalAddress
    ) throws(AllocatorError) {
        guard rawStart >= startRam && rawEnd <= startRam + sizeRam else { throw .addressInvalid(rawStart) }
        guard rawStart < rawEnd else { throw .addressRangeInvalid(from: rawStart, to: rawEnd) }
        
        let start = alignUp  (max(rawStart, startRam), Self.pageSize)
        let end   = alignDown(min(rawEnd, startRam + sizeRam), Self.pageSize)
        
        var current = start
        
        while current < end {
            let remaining = end - current
            
            let order = try findMaxOrder(
                address      : current,
                remainingSize: remaining
            )
            
            try mergeAndInsert(address: current, order: order)

            current += try blockSize(order)
        }
    }
    
    
    // MARK: - Helpers
    
    private func mergeAndInsert(
        address: PhysicalAddress,
        order  : UInt8
    ) throws(AllocatorError) {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        var currentAddress = address
        var currentOrder   = order

        while currentOrder < Self.maxOrder {
            let buddyAddress = try buddyOf(address: currentAddress, order: currentOrder)

            if try isBlockFree(buddyAddress, order: currentOrder) {
                if !(try removeFreeBlock(address: buddyAddress, order: currentOrder)) {
                    fatalError("PPM: Buddy block in list not found - Corrupted structures")
                }
                
                currentAddress = min(currentAddress, buddyAddress)
                
            } else { break }
            
            currentOrder += 1
        }
        
        try pushFreeBlock(address: currentAddress, order: currentOrder)
        try clearBitmapRange(address: currentAddress, order: currentOrder)
    }
 
    private func blockSize(_ order: UInt8) throws(AllocatorError) -> UInt64 {
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order)  }
        return UInt64(Self.pageSize << order)
    }
    
    private func findMaxOrder(
        address      : UInt64,
        remainingSize: UInt64
    ) throws(AllocatorError) -> UInt8 {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        
        var order = Self.maxOrder
        while order > 0 {
            let blockSize = try blockSize(order)
            
            if remainingSize >= blockSize &&
                address % blockSize == 0 {
                return order
            }
            
            order -= 1
        }
        
        return 0 // 4KB
    }
    
    private func buddyOf(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) -> UInt64 {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        
        let rel = address - startRam
        let b   = try blockSize(order)
        
        return startRam + (rel ^ b)
    }
    
    
    private func alignUp(
        _ x: UInt64,
        _ a: UInt64
    ) -> UInt64 { (x + a - 1) & ~(a - 1) }
    
    private func alignDown(
        _ x: UInt64,
        _ a: UInt64
    ) -> UInt64 { x & ~(a - 1) }
    
    private func getPageIndex(address: UInt64) throws(AllocatorError) -> Int {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        
        return Int((address - startRam) / Self.pageSize)
    }
    
    private func setBit(_ index: Int) {
        bitmap[index / 8] |= (1 << UInt8(index % 8))
    }
    
    private func clearBit(_ index: Int) {
        bitmap[index / 8] &= ~(1 << UInt8(index % 8))
    }
    
    
    private func setBitmapRange(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        let startPage = try getPageIndex(address: address)
        let pageCount = 1 << order
        
        for i in 0..<pageCount {
            setBit(startPage + i)
        }
    }
    
    private func clearBitmapRange(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        let startPage = try getPageIndex(address: address)
        let pageCount = 1 << order
        for i in 0..<pageCount { clearBit(startPage + i) }
    }
    
    
    private func isBlockFree(
        _ address: UInt64,
        order    : UInt8
    ) throws(AllocatorError) -> Bool {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        let startPage = try getPageIndex(address: address)
        let pageCount = 1 << order
        for i in 0..<pageCount {
            if testBit(startPage + i) { return false }
        }
        
        return true
    }
    
    
    private func isValidBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) -> Bool {
        
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        return address % (try blockSize(order)) == 0
    }
    
    
    /// Physical address of the order's free-list head, or 0 if the list is
    /// empty (kept returning a raw address so `alloc` is unchanged).
    private func getFreeListHead(order: UInt8) throws(AllocatorError) -> UInt64 {
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }

        // `.pointee` mutates/reads the list IN PLACE (an addressor), unlike the
        // `freeLists[order]` subscript which copies the whole 40-byte struct in
        // and out — fatal with the MMU off (unaligned 16-byte ldp on Device
        // memory). All free-list access below goes through `.pointee` for this.
        if let head = (freeLists + Int(order)).pointee.head {
            return UInt64(UInt(bitPattern: head))
        }
        return 0
    }


    private func pushFreeBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) {
        guard address >= startRam && address < startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }

        let block = UnsafeMutablePointer<FreeBlock>(bitPattern: UInt(address))!
        (freeLists + Int(order)).pointee.pushBack(block)
    }

    private func popFreeBlock(order: UInt8) throws(AllocatorError) -> UInt64? {
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }

        guard let block = (freeLists + Int(order)).pointee.popFront() else { return nil }
        return UInt64(UInt(bitPattern: block))
    }

    /// Unlink a known-free block from its order list in O(1).
    ///
    /// The buddy invariant guarantees the block is actually in `freeLists[order]`
    /// when this is called (it is reached only after `isBlockFree` confirms a
    /// maximally-merged free buddy at exactly this order), so the doubly-linked
    /// `remove(element:)` can splice it directly instead of scanning the list.
    private func removeFreeBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) -> Bool {
        guard address >= startRam && address < startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }

        let block = UnsafeMutablePointer<FreeBlock>(bitPattern: UInt(address))!
        (freeLists + Int(order)).pointee.remove(element: block)
        return true
    }
    
    // MARK: - Testing
    
    private func testBit(_ index: Int) -> Bool {
        (bitmap[index / 8] & (1 << UInt8(index % 8))) != 0
    }
    
}
