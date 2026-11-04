# Memory syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

These operations distinguish a virtual reservation, resident backing and the capability that owns a shared allocation. DMA buffers add a fourth state: backing a device may still write after every holder has gone. Sizes are bytes unless a parameter explicitly says pages. One page is 4096 bytes.

The sentinel conventions differ: `mmap`/`shmMap` return 0 on failure, while `brk` and the range-retirement operations use `UInt64.max`. Check the result of the specific operation.

`munmap` removes the reservation. SHM and DMA windows and the `brk` VMA must be removed whole; an exact or enclosing range is allowed, but a partial cut is refused without changing mappings or charges. Anonymous and raw initrd regions may split, preserving their permissions, memory type and lazy/COW flags. `decommit` releases backing while preserving the reservation. The kernel may suspend and resume a long retirement before returning its final status. See [Memory management](../Memory.md).

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 11 | [`brk`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/BrkSyscall.swift) | `x0`: requested break; 0 queries it | `x0`: resulting/current break; `UInt64.max` on failure. |
| 12 | [`mmap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/MmapSyscall.swift) | `x0`: requested bytes | `x0`: mapped virtual address; 0 on failure. |
| 13 | [`munmap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/MunmapSyscall.swift) | `x0`: virtual address; `x1`: bytes | `x0`: 0 on success; `UInt64.max` on failure. |
| 14 | [`decommit`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DecommitSyscall.swift) | `x0`: virtual address; `x1`: bytes | `x0`: 0 on success; `UInt64.max` on failure. |
| 26 | [`shmCreate`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/ShmCreate.swift) | `x0`: page count, 1 to 256 | `x0`: shared-region handle; `x1`: caller mapping. Failure: `UInt64.max`, 0. Exactly that many frames are charged and held, possibly from several non-adjacent blocks. |
| 27 | [`shmMap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/ShmMap.swift) | `x0`: shared-region handle; `x1`: writable flag, 0 or 1 | `x0`: virtual address; 0 on failure. Writable access requires write rights. |
| 28 | [`shmPages`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/ShmPages.swift) | `x0`: shared-region handle | `x0`: page count; 0 for an invalid or unsuitable capability. |
| 37 | [`dmaAlloc`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DmaAlloc.swift) | `x0`: page count, 1 to 256; `x1`: handle of a device window carrying `.dma` | `x0`: DMA-region handle; `x1`: virtual mapping. Failure: `UInt64.max`, 0. One contiguous block, rounded up to a power of two, bound to that window; the whole block is charged. |
| 38 | [`dmaPhysical`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DmaPhysical.swift) | `x0`: DMA-region handle | `x0`: physical base address; `UInt64.max` on failure. Marks the buffer as visible to a device, which changes what happens when its last holder lets go. |
| 57 | [`dmaReclaim`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DmaReclaim.swift) | `x0`: handle of a device window carrying `.dma` | `x0`: frames given back to the page manager, zero included; `UInt64.max` when the handle is not such a window. |

## DMA buffers and the quarantine

A `.dma` buffer is one physically contiguous buddy block, and `dmaAlloc` charges its creator for the whole block: a seven-page request holds and costs eight frames. A `.shared` region is the opposite case, exactly `pageCount` frames that need not be adjacent.

There is no IOMMU, so a device that was handed a buffer's physical address may keep writing there after the driver is gone. A buffer is therefore treated differently once `dmaPhysical` has given its address out:

| Step | What happens |
| --- | --- |
| `dmaAlloc` | The buffer records the base of the device window it was minted through and charges its creator the whole block. |
| Last holder lets go, address never asked for | The frames go back to the page manager and the creator is refunded at once. |
| Last holder lets go, address was asked for | The region moves to the DMA quarantine with its frames and its charge. A creator that is still alive keeps paying; one that died stopped paying at teardown. |
| `dmaReclaim(window)` | Every quarantined region bound to that window is offered back to the page manager. A block the manager takes returns its frames and refunds the creator. |

The kernel cannot check that the device was reset and does not try. `dmaReclaim` needs the same authority as `dmaAlloc` (a device window with `.dma`), so a false declaration frees memory that a process already inside the trusted base could have aimed the device at anyway. A buffer something still holds is never on the quarantine, so the caller's own live buffer survives the call, and a region bound to another window is not touched.

A block the page manager refuses is not freed, not refunded and not forgotten. The entry stays as refused, with what the manager's books said about the block, and its frames and charge stay. A later reclaim of the same device only reads the books again. It never frees a refused block, because one that now reads live may belong to somebody else. If the books now say the block is already free, the entry is closed and counted as a double free: those frames went back while a device could still write them. Neither case is in the returned count.

`SystemStats` reports the quarantined pages and regions, the refused pages and the double frees; see [System syscalls](System.md). The BlockServer driver calls `dmaReclaim` on its own window right after resetting the device, so the buffers a dead predecessor left are released at the next start.

## Userland API

The [memory SDK](../../../Sources/SDK/Memory/RXMemory.swift) exposes address/status returns directly and wraps two-register allocations in `SharedMemory` and `DmaBuffer`. `dmaReclaim(device:)` returns the raw frame count or `UInt64.max`. `sbrk` is a checked SDK operation built on `brk`, not another syscall.
