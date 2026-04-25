//
//  KernelHeap.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public struct KernelHeap {
    private static var ppmPtr : UnsafeMutablePointer<KernelPPM>? = nil
    private static var buckets: KernelBuckets = KernelBuckets()
    
    private static let physicalOffset: UInt64 = 0xFFFF800000000000
    private static let pageSize      : Int    = 4096
    
    
    private init() {}
    
    public static func initialize(ppmPtr: UnsafeMutablePointer<KernelPPM>) {
        self.ppmPtr = ppmPtr
    }
    
    public static func kmalloc(_ size: UInt) throws(PPMError) -> UnsafeMutableRawPointer? {
        // Size is smaller than one page, because this is a embrional malloc,
        // alloc 4KB.
        guard let ppm = self.ppmPtr,
                size <= 4096, size >= 8 else { return nil }
        
        let sizeNormalized = normalizedToPowerOfTwo(size)
        let shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        let bucketsIndex   = Int(shift - 3)
        
        let bucket = buckets[bucketsIndex]
        
        if let allocatedBlock = bucket {
            let nextPointer = allocatedBlock.assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self).pointee
            buckets[bucketsIndex] = nextPointer
            
            return allocatedBlock
            
        } else {
            let page = try ppm.pointee.alloc(4096, heapShift: shift)
            let virtualAddress = page.address + physicalOffset
            
            let chunkSize   = Int(sizeNormalized)
            let blockCount  = 4096 / chunkSize
            let returnBlock = UnsafeMutableRawPointer(bitPattern: UInt(virtualAddress))!
            
            if blockCount > 1 {
                let firstFreeBlock = returnBlock + chunkSize
                
                buckets[bucketsIndex] = firstFreeBlock
                
                var currentBlock = firstFreeBlock
                
                for _ in 2..<blockCount {
                    let nextBlock = currentBlock + chunkSize
                    currentBlock.assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self).pointee = nextBlock
                    currentBlock = nextBlock
                }
                
                currentBlock.assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self).pointee = nil
            }
            
            return returnBlock
        }
    }
    
    public static func kfree(_ ptr: UnsafeMutableRawPointer) {
        guard let ppm = ppmPtr else { return }
        
        let virtualAddress  = UInt(bitPattern: ptr)
        let physicalAddress = virtualAddress - UInt(physicalOffset)
        let pageRoot        = physicalAddress & ~0xFFF
        
        let pageIndex = Int((UInt64(pageRoot) - ppm.pointee.ramStart) / 4096)
        let heapShift = ppm.pointee.framesMetadata![pageIndex].heapShift
        
        if heapShift == 0 { KernelCPU.panic() }
        
        let indexBucket = Int(heapShift - 3)
        let oldHead     = buckets[indexBucket]
        ptr.assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self).pointee = oldHead
        buckets[indexBucket] = ptr
    }
    
    
    
    private static func normalizedToPowerOfTwo(_ value: UInt) -> UInt8 {
        guard !((value > 0) && ((value & (value - 1)) == 0)) else { return UInt8(value) }
        
        let shift = UInt.bitWidth - value.leadingZeroBitCount
        return UInt8(1 &<< shift)
    }
}
