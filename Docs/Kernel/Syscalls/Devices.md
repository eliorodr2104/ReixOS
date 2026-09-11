# Device and interrupt syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

The kernel validates capability targets and rights before exposing MMIO, interrupt ownership or bus-derived authority. Runtime device protocols live in userland drivers. DMA allocation is listed with [memory syscalls](Memory.md).

An IRQ wait reports pending bits in an interrupt set, not raw GIC interrupt numbers. The driver must service its device and acknowledge the corresponding bits to allow further delivery.

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 29 | [`deviceCap`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/DeviceCapSyscall.swift) | None | `x0`: bootstrap device handle; `UInt32.max` when absent. |
| 30 | [`mapDevice`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/MapDeviceSyscall.swift) | `x0`: device handle | `x0`: mapped virtual address; 0 on failure. |
| 35 | [`irqWait`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIO/IrqWaitSyscall.swift) | `x0`: interrupt handle; `x1`: timeout ticks, 0 for unbounded wait | `x0`: pending-bit mask; 0 on timeout; `UInt64.max` on failure. |
| 36 | [`irqAck`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIO/IrqAckSyscall.swift) | `x0`: interrupt handle; `x1`: serviced-bit mask | `x0`: 0 on acknowledgement; `UInt64.max` on failure. |
| 45 | [`irqBind`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIO/IrqBindSyscall.swift) | `x0`: interrupt handle; `x1`: endpoint handle | `x0`: 0 on binding; `UInt64.max` on failure. |
| 39 | [`deviceRead`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/DeviceAccessSyscall.swift) | `x0`: device handle; `x1`: byte offset | `x0`: zero-extended 32-bit MMIO value; `UInt64.max` on failure. |
| 40 | [`deviceWrite`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/DeviceAccessSyscall.swift) | `x0`: device handle; `x1`: byte offset; `x2`: 32-bit value | `x0`: 0 on write; `UInt64.max` on failure. |
| 41 | [`busDeriveDevice`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/BusDeriveDeviceSyscall.swift) | `x0`: bus handle; `x1`: transport index (`UInt32`) | `x0`: device-window handle; `UInt32.max` on failure. |
| 42 | [`busDeriveInterrupt`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/BusDeriveInterruptSyscall.swift) | `x0`: bus handle; `x1`: transport index (`UInt32`) | `x0`: interrupt-set handle; `UInt32.max` on failure. |

## Userland API

The [device/IRQ SDK functions](../../../Sources/Reix/IPC/RXIPC.swift) include `irqWait`, `irqAck`, `irqBind`, `mapDevice` and bus derivation. `irqBind` returns `Bool`; wait and acknowledgement expose raw `UInt64` results. A valid device address does not imply authority to derive an IRQ or allocate DMA memory.
