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
        
        var shift = UInt8(roundUpPow2(size).trailingZeroBitCount)
        
        if shift < Self.minShift { shift = Self.minShift }
        
        let i = Int(shift - Self.minShift)
        return pop(i) ?? carve(shift: shift, index: i)
    }

    /// Returns `false` when `ptr` is not a live heap block: a bound page always
    /// carries a `shift` in `[minShift, log2(pageSize)]`, while a released or
    /// never-carved page reports `0`. Callers turn `false` into an invalid- /
    /// double-free diagnostic; the free list is left untouched.
    @discardableResult
    public mutating func free(_ ptr: UnsafeMutableRawPointer) -> Bool {
        let page  = Self.pageBase(ptr)
        let shift = backend.shift(ofPage: page)

        guard shift >= Self.minShift,
              shift <= UInt8(Self.pageSize.trailingZeroBitCount) else { return false }

        let i = Int(shift - Self.minShift)

        ptr.storeBytes(of: buckets[i], as: UnsafeMutableRawPointer?.self)
        buckets[i] = ptr

        if backend.onFreeBlock(page: page) { reclaim(page: page, index: i) }

        return true
    }
    

    // MARK: - internals

    @inline(__always)
    public static func pageBase(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: p) & ~UInt(0xFFF))!
    }

    private mutating func pop(_ i: Int) -> UnsafeMutableRawPointer? {
        guard let block = buckets[i] else { return nil }
        
        buckets[i] = block.load(as: UnsafeMutableRawPointer?.self)
        backend.onAllocBlock(page: Self.pageBase(block))
        
        return block
    }

    private mutating func carve(shift: UInt8, index i: Int) -> UnsafeMutableRawPointer? {
        guard let page = backend.acquirePage() else { return nil }
        
        backend.bind(page: page, shift: shift)
        let chunk = 1 << Int(shift)
        let blockCount = Self.pageSize / chunk

        if blockCount > 1 {
            var cur = page + chunk
            buckets[i] = cur
            
            for _ in 2..<blockCount {
                let next = cur + chunk
                cur.storeBytes(of: next, as: UnsafeMutableRawPointer?.self)
                cur = next
            }
            
            cur.storeBytes(of: UnsafeMutableRawPointer?.none, as: UnsafeMutableRawPointer?.self)
        }
        
        return page
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
}
