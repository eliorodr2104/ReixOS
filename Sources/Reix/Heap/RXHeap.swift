//
//  RXHeap.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI


struct UserHeap {
    var slab  = SlabCore<UserArena>(backend: UserArena())
    var large = InlineArray<32, LargeRegion>(repeating: LargeRegion())
    var largeBytes   : UInt = 0
    var highWaterBytes: UInt = 0

    mutating func alloc(size: UInt, alignment: UInt) -> UnsafeMutableRawPointer? {
        let need = max(roundUpPow2(max(size, 1)), max(alignment, 1))
        if need <= 4096 {
            let pointer = slab.alloc(size: need)
            if pointer != nil { recordHighWater() }
            return pointer
        }
        
        return allocLarge(size: size, alignment: alignment)
    }

    mutating func free(_ ptr: UnsafeMutableRawPointer) {
        let arena = UInt(bitPattern: ptr)
        
        if arena >= slab.backend.arenaBase && arena < slab.backend.arenaEnd {
            slab.free(ptr)
        } else { freeLarge(arena) }
    }

    private mutating func allocLarge(
        size     : UInt,
        alignment: UInt
    ) -> UnsafeMutableRawPointer? {
        guard alignment <= 4096,
              size <= UInt.max - 4095,
              let slot = (0..<large.count).first(where: { large[$0].base == 0 })
        else { return nil }
        
        let rounded = (size + 4095) & ~UInt(4095)
        let base = mmap(size: UInt64(rounded))
        if base == 0 { return nil }

        large[slot] = LargeRegion(base: UInt(base), size: rounded)
        largeBytes += rounded
        recordHighWater()
        
        return UnsafeMutableRawPointer(bitPattern: UInt(base))
    }

    private mutating func freeLarge(_ arena: UInt) {
        for i in 0..<large.count where large[i].base == arena {
            _ = munmap(addr: UInt64(arena), size: UInt64(large[i].size))
            largeBytes -= large[i].size
            large[i] = LargeRegion()
            return
        }
    }

    private mutating func recordHighWater() {
        let slabBytes = slab.backend.arenaEnd >= slab.backend.arenaBase
            ? slab.backend.arenaEnd - slab.backend.arenaBase
            : 0
        highWaterBytes = max(highWaterBytes, slabBytes + largeBytes)
    }
}


// MARK: - Public API Heap for Swift

private nonisolated(unsafe) var gHeap = UserHeap()

@_cdecl("reix_posix_memalign")
func reix_posix_memalign(
    _ memptr   : UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: UInt,
    _ size     : UInt
) -> Int32 {
    if alignment < 8 || (alignment & (alignment - 1)) != 0 { return 22 } // EINVAL: pow2 & multiple of 8
    
    guard let pointer = gHeap.alloc(size: max(size, 1), alignment: alignment) else { return 12 } // ENOMEM
    
    memptr.pointee = pointer
    return 0
}

@_cdecl("reix_free")
func reix_free(_ ptr: UnsafeMutableRawPointer?) {
    if let p = ptr { gHeap.free(p) }
}

@_cdecl("reix_malloc")
func reix_malloc(_ size: UInt) -> UnsafeMutableRawPointer? {
    gHeap.alloc(size: max(size, 1), alignment: 16)
}

/// Maximum bytes reserved concurrently by this process's slab arena and large
/// mappings. The counter is monotonic for the process lifetime.
public func userHeapHighWaterBytes() -> UInt {
    gHeap.highWaterBytes
}
