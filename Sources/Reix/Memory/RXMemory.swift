//
//  RXMemory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//


/// Move the program break to `newBreak` and return the resulting break.
///
/// Passing `0` queries the current break without modifying it. Shrinking
/// is silently ignored in the current milestone: passing a value below
/// the current break returns the current break unchanged.
///
/// On failure the kernel returns `RXMemoryError.memoryFailure` (no aligned region
/// available, request outside the user heap area).
@inline(__always)
public func brk(_ newBreak: UInt64) -> UInt64 {
    _syscall(.brk, newBreak)
}


/// Bump the program break by `delta` bytes and return the address of
/// the previous break (POSIX `sbrk` semantics).
///
/// Returns `RXMemoryError.memoryFailure` if the underlying `brk` rejects the new
/// break. Pass `0` to query the current break without growing.
@inline(__always)
public func sbrk(_ delta: Int64) -> UInt64 {
    let current = brk(0)

    if delta == 0 { return current }

    let target = UInt64(Int64(current) + delta)
    let result = brk(target)

    if result == RXMemoryError.memoryFailure {
        return result
    }
    
    return current
}


/// Reserve an anonymous read/write region of `size` bytes in the mmap
/// area. The region is lazily backed: physical pages are allocated only
/// when the user touches them.
///
/// Returns the base virtual address of the region, or `0` on failure.
@inline(__always)
public func mmap(size: UInt64) -> UInt64 {
    _syscall(.mmap, size)
}


/// Release the pages of `[addr, addr + size)`, previously reserved by `mmap`.
///
/// The range does not have to match one whole allocation: it may release part
/// of a region, span several of them, and any unmapped gap inside it is
/// ignored. `addr` must be page-aligned and `size` is rounded up to the page.
///
/// Returns `0` on success, `RXMemoryError.memoryFailure` on failure (unaligned address,
/// range outside user space, or nothing mapped anywhere inside it).
@inline(__always)
public func munmap(addr: UInt64, size: UInt64) -> UInt64 {
    _syscall(.munmap, addr, size)
}


/// Drop the physical backing of the pages in [addr, addr+size) while keeping
/// the reservation, so a lazily backed page re-faults zero-filled on next touch.
///
/// `addr` must be page-aligned and `size` rounds up. The range may cross several
/// regions and skip unmapped gaps, but every region it touches must be anonymous:
/// shared and device frames are not this process's to give back, and a range that
/// reaches into one is refused in full rather than in part. Returns `0`, or
/// `RXMemoryError.memoryFailure` on failure.
///
/// Note this is not `munmap`: the reservation survives, so the address stays
/// yours. Only regions that fault in lazily come back, decommitting eagerly
/// mapped pages (an ELF segment) is one-way and the next access is fatal.
@inline(__always)
public func decommit(addr: UInt64, size: UInt64) -> UInt64 {
    _syscall(.decommit, addr, size)
}

/// Create a shared-memory region of `pageCount` 4 KiB pages, mapped read/write
/// into the caller. Returns the cap handle and the base virtual address;
/// `handle == UInt32.max` means creation failed (no memory, no VA gap).
@inline(__always)
public func shmCreate(pageCount: UInt64) -> SharedMemory {

    let raw = ShmCreateRaw(
        SyscallNumber.shmCreate.rawValue,
        pageCount
    )

    return SharedMemory(
        handle : UInt32(truncatingIfNeeded: raw.handle),
        address: raw.address
    )
}

@inline(__always)
public func shmMap(handle: UInt32) -> UInt64 {
    _syscall(.shmMap, UInt64(handle))
}


// MARK: - Direct Memory Access

/// Allocate `pageCount` physically contiguous, non-cacheable pages a device can
/// transfer into, mapped read/write into the caller.
///
/// `device` is a device-window capability this process holds. It is the price of
/// entry rather than a parameter of the buffer: what the returned capability is
/// allowed to reveal is a physical address, and with no IOMMU on this machine
/// that is authority over all of memory. Requiring a device capability keeps
/// that authority with the processes that already had it.
///
/// `handle == UInt32.max` means the allocation failed, or the caller does not
/// hold the device capability it named.
@inline(__always)
public func dmaAlloc(
    device   : UInt32,
    pageCount: UInt64
) -> DmaBuffer {

    let raw = ShmCreateRaw(
        SyscallNumber.dmaAlloc.rawValue,
        pageCount,
        UInt64(device)
    )

    return DmaBuffer(
        handle : UInt32(truncatingIfNeeded: raw.handle),
        address: raw.address
    )
}


/// The physical base of a buffer `dmaAlloc` returned, for writing into a
/// device's descriptors. `UInt64.max` when the handle does not name one, which
/// includes every ordinary shared region.
@inline(__always)
public func dmaPhysical(handle: UInt32) -> UInt64 {
    _syscall(.dmaPhysical, UInt64(handle))
}
