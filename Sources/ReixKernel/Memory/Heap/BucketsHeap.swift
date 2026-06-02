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
        guard size <= UInt(Self.pageSize), size != 0 else {
            Arch.CPU.panic("Kmalloc Failed, struct is greater than page size")
        }

        let sizeNormalized = Self.normalizedToPowerOfTwo(size)
        let shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        
        guard shift >= 3 else {
            Arch.CPU.panic("Kmalloc Failed, shift is not valid value")
        }
        
        let bucketsIndex = Int(shift - 3)

        if let block = popBlock(bucketsIndex: bucketsIndex) {
            return block
        }
        guard let block = carvePage(shift: shift, bucketsIndex: bucketsIndex) else {
            Arch.CPU.panic(errorMessage)
        }
        return block
    }
    
    public mutating func kmalloc<Object: RXObject>(
        _ type: Object.Type,
        _ capacity: Int = 1
    ) -> UnsafeMutablePointer<Object> {
        
        let objectSize = UInt(MemoryLayout<Object>.stride * capacity)
        guard objectSize <= UInt(Self.pageSize) else {
            Arch.CPU.panic("Kmalloc Failed, struct is greater than page size")
        }

        let sizeNormalized = Self.normalizedToPowerOfTwo(objectSize)
        var shift          = UInt8(sizeNormalized.trailingZeroBitCount)
        // Clamp to the smallest bucket (8 B). Without this, sub-8-byte objects
        // give shift < 3 and `shift - 3` underflows the bucket index.
        if shift < 3 { shift = 3 }
        let bucketsIndex   = Int(shift - 3)

        let raw = popBlock(bucketsIndex: bucketsIndex)
            ?? carvePage(shift: shift, bucketsIndex: bucketsIndex)

        guard let rawMemoryBlock = raw else {
            Arch.CPU.panic(Object.errorMessageAllocation)
        }

        return rawMemoryBlock.bindMemory(
            to      : Object.self,
            capacity: capacity
        )
    }


    public mutating func kfree(_ ptr: UnsafeMutableRawPointer) {
        let pageIndex = heapPageIndex(virtual: UInt(bitPattern: ptr))
        let heapShift = ppmPtr.pointee.framesMetadata![pageIndex].heapShift

        if heapShift == 0 { Arch.CPU.panic("kfree: page does not belong to heap") }

        let indexBucket = Int(heapShift - 3)

        let oldHead = buckets[indexBucket]
        ptr.storeBytes(of: oldHead, as: UnsafeMutableRawPointer?.self)
        buckets[indexBucket] = ptr

        // One more free block on this page; once every block is free the whole
        // page is returned to the PPM instead of being stranded in this bucket
        // forever (previously the heap never gave a page back).
        ppmPtr.pointee.framesMetadata![pageIndex].heapFreeCount += 1

        let blockCount = UInt16(Self.pageSize / (1 << Int(heapShift)))
        if ppmPtr.pointee.framesMetadata![pageIndex].heapFreeCount >= blockCount {
            reclaimPage(pageIndex: pageIndex, bucketsIndex: indexBucket)
        }
    }


    // MARK: - Per-page slab accounting

    /// Frame index of the heap page backing a high-half block pointer.
    private func heapPageIndex(virtual: UInt) -> Int {
        let phys     = UInt64(virtual - UInt(Self.physicalOffset))
        let pageRoot = phys & ~UInt64(0xFFF)
        return Int((pageRoot - ppmPtr.pointee.ramStart) / 4096)
    }

    /// Pop a block from a bucket, accounting it as allocated (one fewer free
    /// block on its page). Returns nil if the bucket is empty.
    private mutating func popBlock(bucketsIndex: Int) -> UnsafeMutableRawPointer? {
        guard let block = buckets[bucketsIndex] else { return nil }
        buckets[bucketsIndex] = block.load(as: UnsafeMutableRawPointer?.self)

        let idx = heapPageIndex(virtual: UInt(bitPattern: block))
        if ppmPtr.pointee.framesMetadata![idx].heapFreeCount > 0 {
            ppmPtr.pointee.framesMetadata![idx].heapFreeCount -= 1
        }
        return block
    }

    /// Allocate a fresh page, slice it into `bucketsIndex`-sized blocks, push
    /// the surplus on the free list and return the first. Seeds the page's
    /// free-block count so `kfree` can later detect when it has fully emptied.
    private mutating func carvePage(shift: UInt8, bucketsIndex: Int) -> UnsafeMutableRawPointer? {
        guard let page = try? ppmPtr.pointee.alloc(4096, heapShift: shift) else { return nil }

        let virtualAddress = page.address + Self.physicalOffset
        let chunkSize      = 1 << Int(shift)
        let blockCount     = Self.pageSize / chunkSize
        let returnBlock    = UnsafeMutableRawPointer(bitPattern: UInt(virtualAddress))!

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

        // One block is returned (allocated); the remaining blockCount-1 are free.
        let idx = Int((page.address - ppmPtr.pointee.ramStart) / 4096)
        ppmPtr.pointee.framesMetadata![idx].heapFreeCount = UInt16(blockCount - 1)

        return returnBlock
    }

    /// Unlink every block of a now-empty page from its bucket free list, mark
    /// the frame non-heap and return it to the PPM.
    private mutating func reclaimPage(pageIndex: Int, bucketsIndex: Int) {
        let pagePhys     = ppmPtr.pointee.ramStart + UInt64(pageIndex) * 4096
        let pageVirtBase = UInt(pagePhys) + UInt(Self.physicalOffset)

        var prev: UnsafeMutableRawPointer? = nil
        var curr = buckets[bucketsIndex]
        while let block = curr {
            let next = block.load(as: UnsafeMutableRawPointer?.self)

            if (UInt(bitPattern: block) & ~UInt(0xFFF)) == pageVirtBase {
                if let p = prev {
                    p.storeBytes(of: next, as: UnsafeMutableRawPointer?.self)
                } else {
                    buckets[bucketsIndex] = next
                }
            } else {
                prev = block
            }

            curr = next
        }

        ppmPtr.pointee.framesMetadata![pageIndex].heapShift     = 0
        ppmPtr.pointee.framesMetadata![pageIndex].heapFreeCount = 0
        try? ppmPtr.pointee.free(PhysicalPage(address: pagePhys, order: 0))
    }

    private static func normalizedToPowerOfTwo(_ value: UInt) -> UInt {
        guard !((value > 0) && ((value & (value - 1)) == 0)) else { return value }

        let shift = UInt.bitWidth - value.leadingZeroBitCount
        return 1 &<< shift
    }
}
