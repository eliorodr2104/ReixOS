//
//  PhysicalPageManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//


public struct PhysicalPageManager<A: Allocator> {
    
    private let allocator     : A
    
    public  let ramStart      : UInt64
    public  let ramSize       : UInt64
        
    public  var framesMetadata: UnsafeMutablePointer<FrameInfo>?
    
    
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
    }
    
    
    public mutating func retain(_ address: PhysicalAddress) throws(PPMError) {
        let indexMetadata = Int((address - ramStart) / 4096)
        
        guard indexMetadata >= 0 else {
            throw .invalidRefCount(indexMetadata)
        }
        
        var metadata = framesMetadata![indexMetadata]
        metadata.refCount += 1
    }
    
    
    public mutating func refCount(_ address: PhysicalAddress) -> UInt32 {
        let indexMetadata = Int((address - ramStart) / 4096)
        
        let metadata = framesMetadata![indexMetadata]
        return metadata.refCount
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


extension PhysicalPageManager where A == BuddyAllocator {
    
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
        let freeListsSize: UInt64 = 12 * 8
        
        let framesMetadataAddress = (freeListsAddr + freeListsSize + 0xFFF) & ~0xFFF
        let framesMetadataSize    = totalPages * UInt64(MemoryLayout<FrameInfo>.stride)
        
        let reservedEnd           = (framesMetadataAddress + framesMetadataSize + 0xFFF) & ~0xFFF
        
        self.framesMetadata         = UnsafeMutablePointer(bitPattern: UInt(framesMetadataAddress))
        framesMetadata?.initialize(repeating: FrameInfo(refCount: 0, order: 0, flags: .none), count: Int(totalPages))
        
        let dtbEnd = (UInt64(Kernel.platformInfo.dtbBase + UInt64(Kernel.platformInfo.dtbSize)) + 0xFFF) & ~0xFFF
        
        var absoluteSafeStart = reservedEnd
        if evtEndAddr > absoluteSafeStart { absoluteSafeStart = evtEndAddr }
        if dtbEnd > absoluteSafeStart { absoluteSafeStart = dtbEnd }
        
        absoluteSafeStart = (absoluteSafeStart + 0xFFF) & ~0xFFF
        
        self.allocator = BuddyAllocator(
            start           : Kernel.platformInfo.ram.base,
            size            : Kernel.platformInfo.ram.size,
            bitmapAddress   : bitmapAddr,
            freeListsAddress: freeListsAddr
        )
        
        setRangeMetadata(
            from: Kernel.platformInfo.ram.base,
            to  : absoluteSafeStart,
            flag: .reserved
        )
        
        try freeSegment(from: absoluteSafeStart, to: ramEnd)
        
    }
}
