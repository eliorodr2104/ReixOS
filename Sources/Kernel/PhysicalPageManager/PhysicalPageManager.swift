//
//  PhysicalPageManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//


@frozen
public struct PhysicalPageManager<A: Allocator> {
    private let allocator: A
    public  var framesMetadata: UnsafeMutablePointer<FrameInfo>?
    
    public let ramStart: UInt64
    public let ramSize: UInt64
    
    
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
            
            var metadata = framesMetadata![indexMetadata]
            metadata.refCount  = 1
            metadata.order     = frame.order
            metadata.flags     = flag
            metadata.heapShift = heapShift
            framesMetadata![indexMetadata] = metadata
            
            return frame
            
        } catch { throw .allocationFailed(reason: error) }
        
    }
    
    
    public func free(_ page: consuming PhysicalPage) throws(PPMError) {
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
        
        guard !flag.contains(.kernel), !flag.contains(.reserved) else {
            throw .protectedMemoryViolation
        }

        
        metadata.refCount -= 1
        framesMetadata![indexMetadata] = metadata
        
        do {
            if metadata.refCount == 0 {
                metadata.flags = .none
                try allocator.free(page)
            }
            
        } catch { throw .allocationFailed(reason: error) }
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
    
    
    
    public func testPPM() throws(PPMError) {
        kprint("\n--- Starting PPM Test Suite ---")
        
        kprint("\nTest 1: Basic Allocation...")
        let page1 = try self.alloc(4096)
        kprintf("Allocated page at: 0x%x\n", page1.address)
        
        let idx1 = Int((page1.address - ramStart) / 4096)
        if framesMetadata![idx1].refCount != 1 {
            kprintf("FAILED: refCount should be 1, found %d\n", UInt64(framesMetadata![idx1].refCount))
        }
        
        kprint("Test 2: Order Allocation (16KB)...")
        let pageBig = try self.alloc(16384)
        kprintf("Allocated 16KB at: 0x%x (Order: %d)\n", pageBig.address, UInt64(pageBig.order))
        
        try self.free(pageBig)
        kprint("Large page freed.")
        
        kprint("\nTest 3: Reference Counting Logic...")
        let page2 = try self.alloc(4096)
        let page2Address = page2.address
        let idx2  = Int((page2.address - ramStart) / 4096)
        
        framesMetadata![idx2].refCount += 1
        kprintf("Manual retain: refCount is now %d\n", UInt64(framesMetadata![idx2].refCount))
        
        try self.free(page2)
        if framesMetadata![idx2].refCount != 1 {
            kprint("FAILED: refCount should be 1 after first free")
            
        } else {
            kprint("First free kept the page alive (Correct).")
        }
        
        let page2Extra = PhysicalPage(address: page2Address, order: 0)
        try self.free(page2Extra)
        
        if framesMetadata![idx2].refCount != 0 {
            kprint("FAILED: refCount should be 0 now")
        } else {
            kprint("Second free released the page (Correct).")
        }
        
        kprint("\nTest 4: Memory Protection...")
        let kernelPage = PhysicalPage(address: ramStart + 0x200000, order: 0)
        try self.free(kernelPage)
        
        kprint("Kernel protection check passed (Check debug logs if any).")
        kprint("\n--- PPM Test Suite Completed ---")
    }
}


extension PhysicalPageManager where A == BuddyAllocator {
    
    init(dtbRawAddress: PhysicalAddress) throws(PPMError) {
        let dtbPointer     = UnsafeRawPointer(bitPattern: Int(dtbRawAddress))
        let evtEndAddr     = getOfaddressWithSymbol(of: &_evt_end)
        let kernelTotalEnd = getOfaddressWithSymbol(of: &_kernel_total_end)
        
        var platformInfo = PlatformInfo()
        guard let platformInfo = getPlatformInfo(
            &platformInfo,
            at: dtbPointer
        ) else {
            kprint("Error!")
            while true {}
        }
        
        self.ramStart             = platformInfo.ram.base
        self.ramSize              = platformInfo.ram.size
        
        let ramEnd                = platformInfo.ram.base + platformInfo.ram.size
        
        let bitmapAddr: UInt64    = (kernelTotalEnd + 0xFFF) & ~0xFFF
        
        let totalPages            = platformInfo.ram.size / 4096
        let bitmapBytes           = (totalPages + 7) / 8
        
        let freeListsAddr         = (bitmapAddr + bitmapBytes + 0xFFF) & ~0xFFF
        let freeListsSize: UInt64 = 12 * 8
        
        let framesMetadataAddress = (freeListsAddr + freeListsSize + 0xFFF) & ~0xFFF
        let framesMetadataSize    = totalPages * UInt64(MemoryLayout<FrameInfo>.stride)
        
        let reservedEnd           = (framesMetadataAddress + framesMetadataSize + 0xFFF) & ~0xFFF
        
        self.framesMetadata       = UnsafeMutablePointer(bitPattern: UInt(framesMetadataAddress))
        framesMetadata?.initialize(repeating: FrameInfo(refCount: 0, order: 0, flags: .none), count: Int(totalPages))
        
        let dtbEnd = (UInt64(dtbRawAddress + UInt64(platformInfo.dtbSize)) + 0xFFF) & ~0xFFF
        
        var absoluteSafeStart = reservedEnd
        if evtEndAddr > absoluteSafeStart { absoluteSafeStart = evtEndAddr }
        if dtbEnd > absoluteSafeStart { absoluteSafeStart = dtbEnd }
        
        absoluteSafeStart = (absoluteSafeStart + 0xFFF) & ~0xFFF
        
        self.allocator = BuddyAllocator(
            start           : platformInfo.ram.base,
            size            : platformInfo.ram.size,
            bitmapAddress   : bitmapAddr,
            freeListsAddress: freeListsAddr
        )
        
        setRangeMetadata(
            from: platformInfo.ram.base,
            to  : absoluteSafeStart,
            flag: .reserved
        )
        
        try freeSegment(from: absoluteSafeStart, to: ramEnd)
        
    }
}
