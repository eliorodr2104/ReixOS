//
//  PhysicalPageManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

@_silgen_name("_kernel_start")
private var _kernel_start: UInt8

@_silgen_name("_kernel_end")
private var _kernel_end: UInt8

@_silgen_name("_evt_start")
private var _evt_start: UInt8

@_silgen_name("_evt_end")
private var _evt_end: UInt8


public struct PhysicalPageManager {
    private let allocator: BuddyAllocator?
    private var framesMetadata: UnsafeMutablePointer<FrameInfo>?
    
    private let ramStart: UInt64
    
    init(dtbRawAddress: PhysicalAddress) throws(PPMError) {
        let dtbPointer      = UnsafeRawPointer(bitPattern: Int(dtbRawAddress))
        let kernelEndAddr   = withUnsafePointer(to: &_kernel_end)   { UInt64(UInt(bitPattern: $0)) }
        let kernelStartAddr = withUnsafePointer(to: &_kernel_start) { UInt64(UInt(bitPattern: $0)) }
        let evtStartAddr    = withUnsafePointer(to: &_evt_start) { UInt64(UInt(bitPattern: $0)) }
        let evtEndAddr      = withUnsafePointer(to: &_evt_end) { UInt64(UInt(bitPattern: $0)) }
        
                
        if let ram = getRAMInfo(at: dtbPointer) {
            self.ramStart             = ram.start
            
            let ramEnd                = ram.start + ram.size
            
            // TODO: Add padding for EVT, this is allocated on Kernel end size 
            // Old init bitmap of kernel end addrees
            let bitmapAddr: UInt64    = (evtEndAddr + 0xFFF) & ~0xFFF
            
            let totalPages            = ram.size / 4096
            let bitmapBytes           = (totalPages + 7) / 8
            
            let freeListsAddr         = (bitmapAddr + bitmapBytes + 0xFFF) & ~0xFFF
            let freeListsSize: UInt64 = 12 * 8
            
            let framesMetadataAddress = (freeListsAddr + freeListsSize + 0xFFF) & ~0xFFF
            let framesMetadataSize    = totalPages * UInt64(MemoryLayout<FrameInfo>.stride)
            
            let reservedEnd           = (framesMetadataAddress + framesMetadataSize + 0xFFF) & ~0xFFF
            
            self.framesMetadata       = UnsafeMutablePointer(bitPattern: UInt(framesMetadataAddress))
            framesMetadata?.initialize(repeating: FrameInfo(refCount: 0, order: 0, flags: 0), count: Int(totalPages))
            
            // DTB page-aligned interval
            let dtbStart = UInt64(dtbRawAddress) & ~0xFFF
            let dtbEnd   = (UInt64(dtbRawAddress + ram.dtbSize) + 0xFFF) & ~0xFFF
            
            self.allocator = BuddyAllocator(
                start           : ram.start,
                size            : ram.size,
                bitmapAddress   : bitmapAddr,
                freeListsAddress: freeListsAddr
            )
            
            
            setRangeMetadata(
                from: dtbStart,
                to  : dtbEnd,
                flag: .reserved
            )
            
            setRangeMetadata(
                from: kernelStartAddr,
                to  : reservedEnd,
                flag: .kernel
            )
            
            setRangeMetadata(
                from: evtStartAddr,
                to  : evtEndAddr,
                flag: .reserved
            )
            
            
            try freeSegment(from: kernelEndAddr, to: evtStartAddr)
                        
            if dtbEnd <= ram.start || dtbStart >= kernelStartAddr {
                try freeSegment(from: ram.start, to: kernelStartAddr)
                
            } else {
                try freeSegment(from: ram.start, to: dtbStart)
                try freeSegment(from: dtbEnd, to: kernelStartAddr)
            }
                        
            if dtbEnd <= reservedEnd || dtbStart >= ramEnd {
                try freeSegment(from: reservedEnd, to: ramEnd)
                
            } else {
                try freeSegment(from: reservedEnd, to: dtbStart)
                try freeSegment(from: dtbEnd,   to: ramEnd)
            }
            
        } else { throw(.initRamError) }
    }

    
    public func alloc(
        _ bytes: Int,
        flag   : PageFlags = .none
    ) throws(PPMError) -> PhysicalPage {
        
        guard let allocator = self.allocator, framesMetadata != nil else {
            throw .metadataInconsistency
        }
        
        do {
            if let frame = try allocator.alloc(bytes) {
                let indexMetadata = Int((frame.address - ramStart) / 4096)
                
                var metadata = framesMetadata![indexMetadata]
                metadata.refCount  = 1
                metadata.order     = frame.order
                metadata.flags     = flag.rawValue
                framesMetadata![indexMetadata] = metadata
                
                return frame
            }
            
        } catch { throw .allocationFailed(reason: error) }
        
        throw .allocationFailed(reason: .fullMemory)
    }
    
    
    public func free(_ page: PhysicalPage) throws(PPMError) {
        guard let allocator = allocator, framesMetadata != nil else {
            throw .metadataInconsistency
        }
        
        let indexMetadata = Int((page.address - ramStart) / 4096)
        var metadata = framesMetadata![indexMetadata]
        let flag = PageFlags(rawValue: metadata.flags)
        
        guard metadata.refCount > 0 else {
            throw .invalidRefCount(Int(metadata.refCount))
        }
        
        guard metadata.order == page.order else {
            throw .pageOrderMismatch(expected: page.order, provided: metadata.order)
        }
        
        guard flag != .kernel, flag != .reserved else {
            throw .protectedMemoryViolation
        }
        
        metadata.refCount -= 1
        framesMetadata![indexMetadata] = metadata
        
        do {
            if metadata.refCount == 0 {
                metadata.flags = 0
                try allocator.free(page)
            }
            
        } catch { throw .allocationFailed(reason: error) }
    }
    
    
    // MARK: - Helpers
    
    private func setRangeMetadata(
        from: PhysicalAddress,
        to  : PhysicalAddress,
        flag: PageFlags
        
    ) {
        let start = Int((from - ramStart) / 4096)
        let end   = Int((to   - ramStart) / 4096)
        
        for i in start..<end {
            var frame = framesMetadata![i]
            
            frame.refCount  = 1
            frame.flags    |= flag.rawValue
                
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
            guard let allocator = self.allocator else {
                throw .metadataInconsistency
            }
            
            do {
                try allocator.addFreeRange(from: s, to: e)
            } catch { throw .allocationFailed(reason: error) }
        }
    }
    
    
    
    public func testPPM() throws(PPMError) {
        kprint("\n--- Starting PPM Test Suite ---")
        
        kprint("\nTest 1: Basic Allocation...")
        let page1 = try self.alloc(4096)
        kprint("Allocated page at: 0x%x\n", page1.address)
        
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
        let idx2 = Int((page2.address - ramStart) / 4096)
        
        framesMetadata![idx2].refCount += 1
        kprintf("Manual retain: refCount is now %d\n", UInt64(framesMetadata![idx2].refCount))
        
        try self.free(page2)
        if framesMetadata![idx2].refCount != 1 {
            kprint("FAILED: refCount should be 1 after first free")
            
        } else {
            kprint("First free kept the page alive (Correct).")
        }
        
        let page2Extra = PhysicalPage(address: page2.address, order: 0)
        try self.free(page2Extra)
        
        if framesMetadata![idx2].refCount != 0 {
            kprint("FAILED: refCount should be 0 now")
        } else {
            kprint("Second free released the page (Correct).")
        }
        
        kprint("\nTest 4: Memory Protection...")
        let kernelPage = PhysicalPage(address: ramStart + 0x200000, order: 0) // Assumendo kernel a +2MB
        try self.free(kernelPage)
        
        kprint("Kernel protection check passed (Check debug logs if any).")
        kprint("\n--- PPM Test Suite Completed ---")
    }
}
