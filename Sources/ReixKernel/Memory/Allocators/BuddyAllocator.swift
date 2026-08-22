//
//  BuddyAllocator.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

public struct BuddyAllocator: Allocator {

    private let startRam       : PhysicalAddress
    private let sizeRam        : UInt64

    private let bitmap         : UnsafeMutablePointer<UInt8>

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
                
        self.bitmap    = UnsafeMutablePointer<UInt8>(bitPattern: UInt(bitmapAddress))!
        self.freeLists = UnsafeMutablePointer<LinkedList<FreeBlock>>(bitPattern: UInt(freeListsAddress))!

        UnsafeMutableRawPointer(freeLists).initializeMemory(as: UInt8.self, repeating: 0, count: Self.freeListsBytes)

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
        guard try isValidBlock(address: page.address, order: page.order) else {
            throw .addressInvalid(page.address)
        }
        guard try !isBlockFree(page.address, order: page.order) else { throw(.doubleFreeInvalid) }


        try mergeAndInsert(address: page.address, order: page.order)
    }
    
    
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
        
        let start = try alignUp(max(rawStart, startRam), Self.pageSize)
        let end   = alignDown(min(rawEnd, ramEnd), Self.pageSize)
        
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
        
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }
        
        var currentAddress = address
        var currentOrder   = order

        while currentOrder < Self.maxOrder {
            
            guard let buddyAddress = try buddyOf(
                address: currentAddress,
                order  : currentOrder
            ) else { break }
            
            guard try isValidBlock(
                address: buddyAddress,
                order  : currentOrder
            ) else { break }

            if try isBlockFree(buddyAddress, order: currentOrder) {
                
                if !(try removeFreeBlock(
                    address: buddyAddress,
                    order  : currentOrder)) {
                    fatalError("PPM: Buddy block in list not found. Corrupted structures")
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
        let ramEnd = try getRamEnd(address: address)
        
        guard address >= startRam &&
              address < ramEnd else { throw .addressInvalid(address) }
        
        var order = Self.maxOrder
        while order > 0 {
            let blockBytes = try blockSize(order)
            
            if remainingSize >= blockBytes &&
                (address - startRam) % blockBytes == 0 &&
                blockBytes <= ramEnd - address {
                return order
            }
            
            order -= 1
        }
        
        return 0 // 4KB
    }
    
    private func buddyOf(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) -> UInt64? {
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }
        
        let rel         = address - startRam
        let blockBytes  = try blockSize(order)
        let buddyOffset = rel ^ blockBytes

        guard buddyOffset < sizeRam &&
              blockBytes <= sizeRam - buddyOffset else { return nil }
        
        return startRam + buddyOffset
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
    
    private func getPageIndex(address: UInt64) throws(AllocatorError) -> Int {
        let ramEnd = try getRamEnd(address: address)
        
        guard address >= startRam &&
              address < ramEnd else { throw .addressInvalid(address) }
        
        let index = (address - startRam) / Self.pageSize
        guard index < sizeRam / Self.pageSize else {
            throw .addressInvalid(address)
        }
        
        return Int(index)
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
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }
        
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
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }
        
        let startPage = try getPageIndex(address: address)
        let pageCount = 1 << order
        for i in 0..<pageCount { clearBit(startPage + i) }
    }
    
    
    private func isBlockFree(
        _ address: UInt64,
        order    : UInt8
    ) throws(AllocatorError) -> Bool {
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }
        
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
        let ramEnd = try getRamEnd(address: address)
        
        guard address >= startRam &&
              address < ramEnd else { return false }
        
        guard order <= Self.maxOrder else {
            throw .pageOrderInvalid(order)
        }
        
        let blockBytes = try blockSize(order)
        return (address - startRam) % blockBytes == 0 &&
                blockBytes <= ramEnd - address
    }

    private func getRamEnd(address: UInt64) throws(AllocatorError) -> UInt64 {
        let (ramEnd, overflow) = startRam.addingReportingOverflow(sizeRam)
        guard !overflow else { throw .addressInvalid(address) }
        
        return ramEnd
    }
    
    
    /// Physical address of the order's free-list head, or 0 if the list is
    /// empty (kept returning a raw address so `alloc` is unchanged).
    private func getFreeListHead(order: UInt8) throws(AllocatorError) -> UInt64 {
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }

        // `.pointee`, never the `freeLists[order]` subscript, here and in every
        // free-list access below: see the note on `freeLists`.
        if let head = (freeLists + Int(order)).pointee.head {
            return UInt64(UInt(bitPattern: head))
        }
        return 0
    }


    private func pushFreeBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) {
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }

        let block = UnsafeMutablePointer<FreeBlock>(bitPattern: UInt(address))!

        block.pointee.next = nil
        block.pointee.prev = nil

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
        guard try isValidBlock(
            address: address,
            order  : order
        ) else { throw .addressInvalid(address) }

        let block = UnsafeMutablePointer<FreeBlock>(bitPattern: UInt(address))!
        (freeLists + Int(order)).pointee.remove(element: block)
        return true
    }
    
    // MARK: - Testing
    
    private func testBit(_ index: Int) -> Bool {
        (bitmap[index / 8] & (1 << UInt8(index % 8))) != 0
    }
    
}
