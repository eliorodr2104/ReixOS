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
///

import ReixABI

public struct BucketsHeap: KernelHeapInterface {
    
    private var core: SlabCore<PPMBackend>

    public init(ppmPtr: UnsafeMutablePointer<KernelPPM>) {
        core = SlabCore(backend: PPMBackend(ppmPtr: ppmPtr))
    }

    public mutating func kmalloc(
        _ size: UInt,
        errorMessage: String = "Kmalloc Failed"
    ) -> UnsafeMutableRawPointer {
        guard let pointer = core.alloc(size: size) else { Arch.CPU.panic(errorMessage) }
        
        return pointer
    }
    
    public mutating func kmalloc<Object: RXObject>(
        _ type    : Object.Type,
        _ capacity: Int = 1
    ) -> UnsafeMutablePointer<Object> {
        let size = UInt(MemoryLayout<Object>.stride * capacity)
        guard let raw = core.alloc(size: size) else { Arch.CPU.panic(Object.errorMessageAllocation) }
        
        return raw.bindMemory(to: Object.self, capacity: capacity)
    }
    
    @inline(__always)
    public mutating func kfree(_ ptr: UnsafeMutableRawPointer) {
        core.free(ptr)
    }
}
