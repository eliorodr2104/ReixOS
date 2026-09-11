# Memory syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

These operations distinguish a virtual reservation, resident backing and the capability that owns a shared allocation. Sizes are bytes unless a parameter explicitly says pages. One page is 4096 bytes.

The sentinel conventions differ: `mmap`/`shmMap` return 0 on failure, while `brk` and the range-retirement operations use `UInt64.max`. Check the result of the specific operation.

`munmap` removes the reservation. `decommit` releases backing while preserving the reservation. The kernel may suspend and resume a long retirement before returning its final status. See [Memory management](../Memory.md).

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 11 | [`brk`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/BrkSyscall.swift) | `x0`: requested break; 0 queries it | `x0`: resulting/current break; `UInt64.max` on failure. |
| 12 | [`mmap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/MmapSyscall.swift) | `x0`: requested bytes | `x0`: mapped virtual address; 0 on failure. |
| 13 | [`munmap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/MunmapSyscall.swift) | `x0`: virtual address; `x1`: bytes | `x0`: 0 on success; `UInt64.max` on failure. |
| 14 | [`decommit`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DecommitSyscall.swift) | `x0`: virtual address; `x1`: bytes | `x0`: 0 on success; `UInt64.max` on failure. |
| 26 | [`shmCreate`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/ShmCreate.swift) | `x0`: page count | `x0`: shared-region handle; `x1`: caller mapping. Failure: `UInt64.max`, 0. |
| 27 | [`shmMap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/ShmMap.swift) | `x0`: shared-region handle; `x1`: writable flag, 0 or 1 | `x0`: virtual address; 0 on failure. Writable access requires write rights. |
| 28 | [`shmPages`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/ShmPages.swift) | `x0`: shared-region handle | `x0`: page count; 0 for an invalid or unsuitable capability. |
| 37 | [`dmaAlloc`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DmaAlloc.swift) | `x0`: page count; `x1`: device authority handle | `x0`: DMA-region handle; `x1`: virtual mapping. Failure: `UInt64.max`, 0. |
| 38 | [`dmaPhysical`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXMemory/DmaPhysical.swift) | `x0`: DMA-region handle | `x0`: physical base address; `UInt64.max` on failure. |

## Userland API

The [memory SDK](../../../Sources/Reix/Memory/RXMemory.swift) exposes address/status returns directly and wraps two-register allocations in `SharedMemory` and `DmaBuffer`. `sbrk` is a checked SDK operation built on `brk`, not another syscall.
