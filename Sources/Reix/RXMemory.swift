//
//  RXMemory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Sentinel returned by `brk` / `munmap` when the kernel refuses the
/// request. Chosen as `UInt64.max` so that arithmetic on user-space
/// pointers can detect the error without an extra branch.
public let RX_MEM_FAILURE: UInt64 = UInt64.max


/// Move the program break to `newBreak` and return the resulting break.
///
/// Passing `0` queries the current break without modifying it. Shrinking
/// is silently ignored in the current milestone: passing a value below
/// the current break returns the current break unchanged.
///
/// On failure the kernel returns `RX_MEM_FAILURE` (no aligned region
/// available, request outside the user heap area).
@inline(__always)
public func brk(_ newBreak: UInt64) -> UInt64 {
    _syscall(.brk, newBreak)
}


/// Bump the program break by `delta` bytes and return the address of
/// the previous break (POSIX `sbrk` semantics).
///
/// Returns `RX_MEM_FAILURE` if the underlying `brk` rejects the new
/// break. Pass `0` to query the current break without growing.
@inline(__always)
public func sbrk(_ delta: Int64) -> UInt64 {
    let current = brk(0)

    if delta == 0 { return current }

    let target = UInt64(Int64(current) + delta)
    let result = brk(target)

    if result == RX_MEM_FAILURE { return RX_MEM_FAILURE }
    return current
}


/// Reserve an anonymous read/write region of `size` bytes in the mmap
/// area. The region is lazily backed: physical pages are allocated only
/// when the user touches them.
///
/// Returns the base virtual address of the region, or `0` on failure
/// (no free gap, invalid size).
@inline(__always)
public func mmap(size: UInt64) -> UInt64 {
    _syscall(.mmap, size)
}


/// Release a region previously returned by `mmap`. Only full-region
/// unmap is supported in this milestone: `addr` and `size` must match
/// the original allocation.
///
/// Returns `0` on success, `RX_MEM_FAILURE` on failure (address not
/// known, size mismatch).
@inline(__always)
public func munmap(addr: UInt64, size: UInt64) -> UInt64 {
    _syscall(.munmap, addr, size)
}
