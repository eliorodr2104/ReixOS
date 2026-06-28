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
        errorMessage: StaticString = "Kmalloc Failed"
    ) -> UnsafeMutableRawPointer {
        allocBytes(size, errorMessage)
    }

    public mutating func kmalloc<Object: RXAllocatable & ~Copyable>(
        _ type    : Object.Type,
        _ capacity: Int = 1
    ) -> UnsafeMutablePointer<Object> {
        let size = UInt(MemoryLayout<Object>.stride * capacity)

        return allocBytes(size, Object.errorMessageAllocation)
                   .bindMemory(to: Object.self, capacity: capacity)
    }

    @inline(__always)
    public mutating func kfree(_ ptr: UnsafeMutableRawPointer) {
        let page = SlabCore<PPMBackend>.pageBase(ptr)
        let meta = frameInfo(of: page)

        // Multi-page blocks bypass the slab: free the whole order-N frame.
        // `ppm.free` clears the page flags once the refcount reaches zero.
        if meta.pointee.flags.contains(.heapLarge) {
            let phys = UInt64(UInt(bitPattern: page)) - PPMBackend.physicalOffset
            try? core.backend.ppmPtr.pointee.free(
                PhysicalPage(address: phys, order: meta.pointee.order)
            )
            return
        }

        guard core.free(ptr) else { Arch.CPU.panic("kfree: invalid or double free") }
    }

    /// Typed counterpart of `kmalloc<Object>`: deinitializes the pointee(s) and
    /// returns the storage to the slab in one call, so callers never hand-roll
    /// `deinitialize` + a raw-pointer cast.
    @inline(__always)
    public mutating func kfree<Object: ~Copyable>(
        _ ptr  : UnsafeMutablePointer<Object>,
        count  : Int = 1
    ) {
        ptr.deinitialize(count: count)
        kfree(UnsafeMutableRawPointer(ptr))
    }

    // MARK: - internals

    /// Routes by size: blocks up to one page go through the slab, larger
    /// requests are served as a single order-N buddy frame tagged `.heapLarge`.
    private mutating func allocBytes(
        _ size        : UInt,
        _ errorMessage: StaticString
    ) -> UnsafeMutableRawPointer {
        if size > UInt(SlabCore<PPMBackend>.pageSize) {
            guard let page = try? core.backend.ppmPtr.pointee.alloc(
                Int(size),
                flag: .heapLarge
            ) else { Arch.CPU.panic(errorMessage) }

            return UnsafeMutableRawPointer(
                bitPattern: UInt(page.address + PPMBackend.physicalOffset)
            )!
        }

        guard let pointer = core.alloc(size: size) else { Arch.CPU.panic(errorMessage) }

        return pointer
    }

    private func frameInfo(of page: UnsafeMutableRawPointer) -> UnsafeMutablePointer<FrameInfo> {
        let phys = UInt64(UInt(bitPattern: page)) - PPMBackend.physicalOffset
        let idx  = Int((phys - core.backend.ppmPtr.pointee.ramStart) / 4096)

        return core.backend.ppmPtr.pointee.framesMetadata!.advanced(by: idx)
    }
}
