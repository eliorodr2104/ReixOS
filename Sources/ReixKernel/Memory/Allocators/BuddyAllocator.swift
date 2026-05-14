//
//  BuddyAllocator.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

public struct BuddyAllocator: Allocator {
    private let startRam: PhysicalAddress
    private let sizeRam : UInt64
    
    private let bitmap   : UnsafeMutablePointer<UInt8>
    private let freeLists: UnsafeMutableRawPointer
    
    private static let maxOrder: UInt8  = 11
    private static let pageSize: UInt64 = 4096
    
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
        self.freeLists = UnsafeMutableRawPointer(bitPattern: UInt(freeListsAddress))!
        
        freeLists.initializeMemory(as: UInt64.self, repeating: 0, count: Int(Self.maxOrder) + 1)
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
    
    
    private func getFreeListHead(order: UInt8) throws(AllocatorError) -> UInt64 {
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        return freeLists.load(fromByteOffset: Int(order) * 8, as: UInt64.self)
    }
    
    private func setFreeListHead(
        order  : UInt8,
        address: UInt64
    ) throws(AllocatorError) {
        if address != 0 {
            guard address >= startRam && address <= startRam + sizeRam else {
                throw .addressInvalid(address)
            }
        }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        freeLists.storeBytes(of: address, toByteOffset: Int(order) * 8, as: UInt64.self)
    }
    
    
    private func pushFreeBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        let old = try getFreeListHead(order: order)
        let ptr = UnsafeMutableRawPointer(bitPattern: UInt(address))!
        
        ptr.storeBytes(of: old, as: UInt64.self)
        
        try setFreeListHead(order: order, address: address)
    }
    
    private func popFreeBlock(order: UInt8) throws(AllocatorError) -> UInt64? {
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        let head = try getFreeListHead(order: order)
        if head == 0 { return nil }
        let ptr = UnsafeMutableRawPointer(bitPattern: UInt(head))!
        let next = ptr.load(as: UInt64.self)
        
        try setFreeListHead(order: order, address: next)
        
        return head
    }
    
    private func removeFreeBlock(
        address: UInt64,
        order  : UInt8
    ) throws(AllocatorError) -> Bool {
        guard address >= startRam && address <= startRam + sizeRam else { throw .addressInvalid(address) }
        guard order <= Self.maxOrder else { throw .pageOrderInvalid(order) }
        
        var prev: UInt64 = 0
        var curr = try getFreeListHead(order: order)
        
        while curr != 0 {
            let currPtr = UnsafeMutableRawPointer(bitPattern: UInt(curr))!
            let next = currPtr.load(as: UInt64.self)
            
            if curr == address {
                if prev == 0 {
                    try setFreeListHead(order: order, address: next)
                    
                } else {
                    let prevPtr = UnsafeMutableRawPointer(bitPattern: UInt(prev))!
                    prevPtr.storeBytes(of: next, as: UInt64.self)
                    
                }
                return true
            }
            
            prev = curr
            curr = next
        }
        
        return false
    }
    
    // MARK: - Testing
    
    private func testBit(_ index: Int) -> Bool {
        (bitmap[index / 8] & (1 << UInt8(index % 8))) != 0
    }
    
}
