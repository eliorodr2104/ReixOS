//
//  KernelHeap.swift
//  ReixOS
//

/// Bucket-based slab allocator backed by the Physical Page Manager.
///
/// Allocates 4 KiB pages from the PPM and slices them into power-of-two
/// blocks, served through per-size free lists kept inside `KernelBuckets`.
/// Built as an instance struct so its mutable state (free lists, PPM
/// pointer) is explicit and the manager is reachable from every consumer
/// through a stable pointer composed by `Kernel`.
public struct BucketsHeap: KernelHeapInterface {

    private var buckets: InlineArray<10, UnsafeMutableRawPointer?> // 10 * 8 Byte
    private let ppmPtr : UnsafeMutablePointer<KernelPPM>           // 8 Byte

    private static let physicalOffset: UInt64 = 0xFFFF800000000000 // 8 Byte
    private static let pageSize      : Int    = 4096               // 8 Byte

    public init(ppmPtr: UnsafeMutablePointer<KernelPPM>) {
        self.ppmPtr  = ppmPtr
        self.buckets = InlineArray(repeating: nil)
    }

    public mutating func kmalloc(
        _ size        : UInt,
          errorMessage: String = "Kmalloc Failed"
    ) -> UnsafeMutableRawPointer {
        guard size <= UInt(Self.pageSize) else {
            Arch.CPU.panic("Kmalloc Failed, struct is greater than page size")
        }

        let sizeNormalized = Self.normalizedToPowerOfTwo(size)
        let shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        let bucketsIndex   = Int(shift - 3)

        let bucket = buckets[bucketsIndex]

        if let allocatedBlock = bucket {
            let nextPointer = allocatedBlock.load(as: UnsafeMutableRawPointer?.self)
            buckets[bucketsIndex] = nextPointer

            return allocatedBlock

        } else {
            
            do {
                let page = try ppmPtr.pointee.alloc(4096, heapShift: shift)
                let virtualAddress = page.address + Self.physicalOffset

                let chunkSize   = Int(sizeNormalized)
                let blockCount  = Self.pageSize / chunkSize
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
                
            } catch { Arch.CPU.panic(errorMessage) }
        }
    }
    
    public mutating func kmalloc<Object: RXObject>(
        _ type: Object.Type,
        _ capacity: Int = 1
    ) -> UnsafeMutablePointer<Object> {
        
        let objectSize = UInt(MemoryLayout<KernelIPC>.stride)
        guard objectSize <= UInt(Self.pageSize) else {
            Arch.CPU.panic("Kmalloc Failed, struct is greater than page size")
        }

        let sizeNormalized = Self.normalizedToPowerOfTwo(objectSize)
        let shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        let bucketsIndex   = Int(shift - 3)

        let bucket = buckets[bucketsIndex]

        var rawMemoryBlockResult: UnsafeMutableRawPointer?
        if let allocatedBlock = bucket {
            let nextPointer = allocatedBlock.load(as: UnsafeMutableRawPointer?.self)
            buckets[bucketsIndex] = nextPointer

            // Set founded block
            rawMemoryBlockResult = allocatedBlock

        } else {
            do {
                let page = try ppmPtr.pointee.alloc(4096, heapShift: shift)
                let virtualAddress = page.address + Self.physicalOffset

                let chunkSize   = Int(sizeNormalized)
                let blockCount  = Self.pageSize / chunkSize
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

                // Set founded block
                rawMemoryBlockResult = returnBlock
                
            } catch { Arch.CPU.panic(Object.errorMessageAllocation) }
        }
        
        guard let rawMemoryBlock = rawMemoryBlockResult else {
            Arch.CPU.panic("Kmalloc Failed: Memory full")
        }
        
        return rawMemoryBlock.bindMemory(
            to      : Object.self,
            capacity: capacity
        )
        
    }


    public mutating func kfree(_ ptr: UnsafeMutableRawPointer) {
        let virtualAddress  = UInt(bitPattern: ptr)
        let physicalAddress = virtualAddress - UInt(Self.physicalOffset)

        let pageRoot = physicalAddress & ~UInt(0xFFF)

        let pageIndex = Int((UInt64(pageRoot) - ppmPtr.pointee.ramStart) / 4096)
        let heapShift = ppmPtr.pointee.framesMetadata![pageIndex].heapShift

        if heapShift == 0 { Arch.CPU.panic("kfree: page does not belong to heap") }

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
