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

    private let ppmPtr : UnsafeMutablePointer<KernelPPM>
    private var buckets: KernelBuckets

    private static let physicalOffset: UInt64 = 0xFFFF800000000000
    private static let pageSize      : Int    = 4096

    public init(ppmPtr: UnsafeMutablePointer<KernelPPM>) {
        self.ppmPtr  = ppmPtr
        self.buckets = KernelBuckets()
    }

    public mutating func kmalloc(_ size: UInt) throws(PPMError) -> UnsafeMutableRawPointer? {
        guard size <= UInt(Self.pageSize) && size > 0 else { return nil }

        let sizeNormalized = Self.normalizedToPowerOfTwo(size)
        let shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        let bucketsIndex   = Int(shift - 3)

        let bucket = buckets[bucketsIndex]

        if let allocatedBlock = bucket {
            let nextPointer = allocatedBlock.load(as: UnsafeMutableRawPointer?.self)
            buckets[bucketsIndex] = nextPointer

            return allocatedBlock

        } else {
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
        }
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
