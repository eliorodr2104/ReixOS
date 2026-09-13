//
//  SlabCore.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

public struct SlabCore<Backend: SlabBackend> {

    public static var pageSize: Int   { 4096 }
    public static var minShift: UInt8 { 3    } // 8B small block

    public var backend: Backend
    
    private var buckets = InlineArray<10, UnsafeMutableRawPointer?>(repeating: nil)

    public init(backend: Backend) { self.backend = backend }

    // size must be in (0, 4096]; the wrapper routes anything larger to mmap.
    public mutating func alloc(size: UInt) -> UnsafeMutableRawPointer? {
        guard size != 0, size <= UInt(Self.pageSize) else { return nil }

        let rounded = roundUpPow2(size)
        guard rounded != 0 else { return nil }

        var shift = UInt8(rounded.trailingZeroBitCount)
        
        if shift < Self.minShift { shift = Self.minShift }
        
        let i = Int(shift - Self.minShift)
        if buckets[i] != nil { return pop(i) }
        return carve(shift: shift, index: i)
    }

    /// Returns `false` unless `ptr` is the start of a currently live block on a
    /// page owned by this backend. Rejected pointers never touch the free list.
    @discardableResult
    public mutating func free(_ ptr: UnsafeMutableRawPointer) -> Bool {
        guard let location = location(of: ptr) else { return false }

        let result = backend.onFreeBlock(
            page      : location.page,
            blockIndex: location.blockIndex,
            shift     : location.shift
        )
        guard result != .invalid else { return false }

        let i = Int(location.shift - Self.minShift)

        ptr.storeBytes(of: buckets[i], as: UnsafeMutableRawPointer?.self)
        buckets[i] = ptr

        if result == .releasePage {
            reclaim(page: location.page, index: i)
        }

        return true
    }

    /// Size of the bucket that owns `ptr`, only while that exact block is live.
    /// The kernel typed-free wrapper uses this before it invokes any destructor.
    @inline(__always)
    public func allocationSize(of ptr: UnsafeMutableRawPointer) -> UInt? {
        guard let location = location(of: ptr),
              backend.isAllocatedBlock(
                page      : location.page,
                blockIndex: location.blockIndex,
                shift     : location.shift
              )
        else { return nil }

        return UInt(1) << UInt(location.shift)
    }
    

    // MARK: - internals

    @inline(__always)
    public static func pageBase(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: p) & ~UInt(0xFFF))!
    }

    /// Bytes used by a small-bucket bitmap are rounded to whole blocks so none
    /// of the allocator's private liveness state can be handed to a caller.
    @inline(__always)
    public static func reservedBlockCount(forShift shift: UInt8) -> Int {
        guard shift >= Self.minShift, shift < 8 else { return 0 }

        let blockCount = Self.pageSize >> Int(shift)
        let bitmapBytes = ((blockCount + 63) / 64) * 8
        let blockSize = 1 << Int(shift)

        return (bitmapBytes + blockSize - 1) / blockSize
    }

    private mutating func pop(_ i: Int) -> UnsafeMutableRawPointer? {
        guard let block = buckets[i] else { return nil }

        guard let location = location(of: block),
              Int(location.shift - Self.minShift) == i
        else {
            // Preserve the head and fail closed. Post-free writes are outside
            // the allocator contract, but even then this node is not followed
            // into foreign memory or handed out as a live-block alias.
            return nil
        }

        guard backend.onAllocBlock(
            page      : location.page,
            blockIndex: location.blockIndex,
            shift     : location.shift
        ) else { return nil }

        buckets[i] = block.load(as: UnsafeMutableRawPointer?.self)
        
        return block
    }

    private mutating func carve(shift: UInt8, index i: Int) -> UnsafeMutableRawPointer? {
        guard let page = backend.acquirePage() else { return nil }
        
        backend.bind(page: page, shift: shift)
        let chunk = 1 << Int(shift)
        let blockCount = Self.pageSize / chunk
        let firstBlock = Self.reservedBlockCount(forShift: shift)

        if shift < 8 {
            let bitmapWords = (blockCount + 63) / 64
            for word in 0..<bitmapWords {
                page.storeBytes(of: UInt64(0), toByteOffset: word * 8, as: UInt64.self)
            }
        }

        let first = page + firstBlock * chunk
        let location = BlockLocation(page: page, shift: shift, blockIndex: firstBlock)
        guard backend.onAllocBlock(
            page      : location.page,
            blockIndex: location.blockIndex,
            shift     : location.shift
        ) else {
            backend.releasePage(page)
            return nil
        }

        if firstBlock + 1 < blockCount {
            var cur = page + (firstBlock + 1) * chunk
            buckets[i] = cur

            var nextBlock = firstBlock + 2
            while nextBlock < blockCount {
                let next = page + nextBlock * chunk
                cur.storeBytes(of: next, as: UnsafeMutableRawPointer?.self)
                cur = next
                nextBlock += 1
            }

            cur.storeBytes(of: UnsafeMutableRawPointer?.none, as: UnsafeMutableRawPointer?.self)
        }

        return first
    }

    private mutating func reclaim(page: UnsafeMutableRawPointer, index i: Int) {
        let base = UInt(bitPattern: page)
        var prev: UnsafeMutableRawPointer? = nil
        
        var cur = buckets[i]
        while let block = cur {
            let next = block.load(as: UnsafeMutableRawPointer?.self)
            
            if (UInt(bitPattern: block) & ~UInt(0xFFF)) == base {
                if let p = prev {
                    p.storeBytes(of: next, as: UnsafeMutableRawPointer?.self)
                } else { buckets[i] = next }
                
            } else { prev = block }
            
            cur = next
        }
        backend.releasePage(page)
    }

    private struct BlockLocation {
        let page      : UnsafeMutableRawPointer
        let shift     : UInt8
        let blockIndex: Int
    }

    @inline(__always)
    private func location(of ptr: UnsafeMutableRawPointer) -> BlockLocation? {
        let address = UInt(bitPattern: ptr)
        let pageAddress = address & ~UInt(0xFFF)
        guard pageAddress != 0,
              let page = UnsafeMutableRawPointer(bitPattern: pageAddress),
              let shift = backend.shiftIfOwned(ofPage: page)
        else { return nil }

        guard shift >= Self.minShift,
              shift <= UInt8(Self.pageSize.trailingZeroBitCount)
        else { return nil }

        let blockSize = UInt(1) << UInt(shift)
        let offset = address - pageAddress
        guard (offset & (blockSize - 1)) == 0 else { return nil }

        let blockIndex = Int(offset >> UInt(shift))
        guard blockIndex >= Self.reservedBlockCount(forShift: shift),
              blockIndex < Self.pageSize >> Int(shift)
        else { return nil }

        return BlockLocation(page: page, shift: shift, blockIndex: blockIndex)
    }
}
