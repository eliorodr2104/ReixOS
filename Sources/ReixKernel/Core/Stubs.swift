//
//  Stubs.swift
//  ReixOS
//
//  Swift backends for the kernel's freestanding C runtime boundary. The exact C
//  symbols and signatures live in `Native/kernel/KernelRuntimeABI.c`: keeping names
//  such as `malloc` out of Swift avoids the toolchain's reserved-symbol warning.
//
//  These allocation symbols support C callers and explicit Swift raw allocation.
//  ARC-managed kernel objects are outside this boundary: Embedded Swift reserves
//  pointer bit 63 as an immortal-object marker, while ReixOS uses that bit in every
//  high-half direct-map heap pointer. This ABI supports explicit raw allocation;
//  adding kernel ARC requires a separate runtime/mapping design.
//

@_cdecl("reix_kernel_malloc")
public func reixKernelMalloc(_ size: UInt) -> UnsafeMutableRawPointer? {
    guard let heap = Kernel.heap else { return nil }
    return heap.pointee.kmallocAlignedOrNil(size, alignment: 16)
}

@_cdecl("reix_kernel_free")
public func reixKernelFree(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    guard let heap = Kernel.heap else {
        Arch.CPU.panic("kernel runtime free before heap initialization")
    }

    heap.pointee.kfree(pointer)
}

@_cdecl("reix_kernel_posix_memalign")
public func reixKernelPosixMemalign(
    _ memptr   : UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ alignment: UInt,
    _ size     : UInt
) -> Int32 {
    // POSIX requires a power-of-two multiple of sizeof(void *). Returning an
    // error must leave the caller's output untouched.
    guard alignment >= 8,
          (alignment & (alignment - 1)) == 0,
          let memptr
    else { return 22 } // EINVAL

    guard let heap = Kernel.heap,
          let pointer = heap.pointee.kmallocAlignedOrNil(size, alignment: alignment)
    else { return 12 } // ENOMEM

    memptr.pointee = pointer
    return 0
}

@_cdecl("reix_kernel_stack_check_failed")
public func reixKernelStackCheckFailed() {
    Arch.CPU.panic("stack protector: kernel stack corruption detected")
}

/// Compatibility seed for Embedded Swift's `Hasher` while ReixOS has no CSPRNG.
///
/// This byte stream is fixed and predictable. It is not entropy and must never
/// be used for keys, nonces, capabilities, ASLR, or attacker-resistant hashing.
/// Replacing it with real randomness requires a separately designed kernel
/// entropy service; a timer or changing constant would not satisfy that contract.
@_cdecl("reix_kernel_fill_deterministic_hash_seed")
public func reixKernelFillDeterministicHashSeed(
    _ buffer: UnsafeMutableRawPointer?,
    _ count : UInt
) {
    guard let buffer, count <= UInt(Int.max) else { return }
    buffer.initializeMemory(as: UInt8.self, repeating: 0x42, count: Int(count))
}
