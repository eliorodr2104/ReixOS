//
//  KernelHeap.swift
//  ReixOS
//

import ReixABI


/// Bucket-based slab allocator backed by the Physical Page Manager.
///
/// Allocates 4 KiB pages from the PPM and slices them into power-of-two
/// blocks, served through per-size free lists kept inside `KernelBuckets`.
/// Built as an instance struct so its mutable state (free lists, PPM
/// pointer) is explicit and the manager is reachable from every consumer
/// through a stable pointer composed by `Kernel`.
///
public struct BucketsHeap: KernelHeapInterface, Loggable {
    
    public static let nameLog : StaticString = "[HEAP]"
    public static let logLevel: LogLevel     = .info
    
    private var core: SlabCore<PPMBackend>

    public init(ppmPtr: UnsafeMutablePointer<KernelPPM>) {
        core = SlabCore(backend: PPMBackend(ppmPtr: ppmPtr))

        Self.boot("Kernel heap ready.")
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

    /// Failable counterpart of `kmalloc`, for every allocation a syscall can
    /// reach.
    @inline(__always)
    public mutating func kmallocOrNil(_ size: UInt) -> UnsafeMutableRawPointer? {
        allocBytesOrNil(size)
    }

    /// Typed counterpart of `kmallocOrNil`, mirroring `kmalloc<Object>`.
    @inline(__always)
    public mutating func kmallocOrNil<Object: RXAllocatable & ~Copyable>(
        _ type    : Object.Type,
        _ capacity: Int = 1
    ) -> UnsafeMutablePointer<Object>? {
        let size = UInt(MemoryLayout<Object>.stride * capacity)

        return allocBytesOrNil(size)?
                   .bindMemory(to: Object.self, capacity: capacity)
    }

    @inline(__always)
    public mutating func kfree(_ ptr: UnsafeMutableRawPointer) {
        let page = SlabCore<PPMBackend>.pageBase(ptr)
        let meta = frameInfo(of: page)

        if meta.pointee.flags.contains(.heapLarge) {
            
            let phys = UInt64(UInt(bitPattern: page)) - PPMBackend.physicalOffset
            try? core.backend.ppmPtr.pointee.free(
                PhysicalPage(address: phys, order: meta.pointee.order)
            )
            
            return
        }

        guard core.free(ptr) else {
            Arch.CPU.panic("kfree: invalid or double free")
        }
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

    /// Panicking wrapper kept for the boot-time singletons: they have no error
    /// channel and nothing to roll back, so the message is the diagnostic.
    private mutating func allocBytes(
        _ size        : UInt,
        _ errorMessage: StaticString
    ) -> UnsafeMutableRawPointer {
        guard let pointer = allocBytesOrNil(size) else { Arch.CPU.panic(errorMessage) }

        return pointer
    }

    /// Routes by size: blocks up to one page go through the slab, larger
    /// requests are served as a single order-N buddy frame tagged `.heapLarge`.
    #if !hasFeature(Embedded)
    /// Host-only fault injection: the next `n` requests that are allowed to
    /// answer nil succeed, and every one after that fails. `nil` disables it.
    ///
    /// Seamed like `PPMBackend.physicalOffset`, so the machine is compiled
    /// without it. It exists because the four rollbacks in
    /// `ProcessManager.spawnProcess` are otherwise unreachable from a test: each
    /// one needs a heap allocation to fail *after* an address space was created,
    /// and draining the arena makes the address space fail first every time.
    static var failAllocationsAfter: Int? = nil
    #endif


    private mutating func allocBytesOrNil(_ size: UInt) -> UnsafeMutableRawPointer? {
        #if !hasFeature(Embedded)
        if let remaining = Self.failAllocationsAfter {
            guard remaining > 0 else { return nil }
            Self.failAllocationsAfter = remaining - 1
        }
        #endif

        if size > UInt(SlabCore<PPMBackend>.pageSize) {
            guard let page = try? core.backend.ppmPtr.pointee.alloc(
                Int(size),
                flag: .heapLarge
            ) else { return nil }

            return UnsafeMutableRawPointer(
                bitPattern: UInt(page.address + PPMBackend.physicalOffset)
            )!
        }

        return core.alloc(size: size)
    }

    private func frameInfo(of page: UnsafeMutableRawPointer) -> UnsafeMutablePointer<FrameInfo> {
        let phys = UInt64(UInt(bitPattern: page)) - PPMBackend.physicalOffset
        let idx  = Int((phys - core.backend.ppmPtr.pointee.ramStart) / 4096)

        return core.backend.ppmPtr.pointee.framesMetadata!.advanced(by: idx)
    }
}
