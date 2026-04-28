//
//  KernelHeap.swift
//  ReixOS
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
        guard let ppm = self.ppmPtr,
              size <= UInt(pageSize) && size >= 8 else { return nil }
        
        let sizeNormalized = normalizedToPowerOfTwo(size)
        let shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        let bucketsIndex   = Int(shift - 3)
        
        let bucket = buckets[bucketsIndex]
        
        if let allocatedBlock = bucket {
            let nextPointer = allocatedBlock.load(as: UnsafeMutableRawPointer?.self)
            buckets[bucketsIndex] = nextPointer
            
            return allocatedBlock
            
        } else {
            let page = try ppm.pointee.alloc(4096, heapShift: shift)
            let virtualAddress = page.address + physicalOffset
            
            let chunkSize  = Int(sizeNormalized)
            let blockCount = pageSize / chunkSize
            let returnBlock = UnsafeMutableRawPointer(bitPattern: UInt(virtualAddress))!
            
            if blockCount > 1 {
                let firstFreeBlock = returnBlock + chunkSize
                buckets[bucketsIndex] = firstFreeBlock
                
                var currentBlock = firstFreeBlock
                
                for _ in 2..<blockCount {
                    let nextBlock = currentBlock + chunkSize
                    currentBlock.storeBytes(of: nextBlock, as: UnsafeMutableRawPointer?.self)
                    currentBlock = nextBlock
                }
                
                currentBlock.storeBytes(of: nil, as: UnsafeMutableRawPointer?.self)
            }
            
            return returnBlock
        }
    }
    
    public static func kfree(_ ptr: UnsafeMutableRawPointer) {
        guard let ppm = ppmPtr else { return }
        
        let virtualAddress  = UInt(bitPattern: ptr)
        let physicalAddress = virtualAddress - UInt(physicalOffset)
        
        let pageRoot = physicalAddress & ~UInt(0xFFF)
        
        let pageIndex = Int((UInt64(pageRoot) - ppm.pointee.ramStart) / 4096)
        let heapShift = ppm.pointee.framesMetadata![pageIndex].heapShift
        
        if heapShift == 0 { KernelCPU.panic("kfree: page does not belong to heap") }
        
        let indexBucket = Int(heapShift - 3)
        let oldHead     = buckets[indexBucket]
        
        ptr.storeBytes(of: oldHead, as: UnsafeMutableRawPointer?.self)
        buckets[indexBucket] = ptr
    }
    
    private static func normalizedToPowerOfTwo(_ value: UInt) -> UInt {
        guard !((value > 0) && ((value & (value - 1)) == 0)) else { return value }
        
        let shift = UInt.bitWidth - value.leadingZeroBitCount
        return 1 &<< shift
    }
}
