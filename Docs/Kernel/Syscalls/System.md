# Time, diagnostics and power syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

Time, profiling and machine control have different authority checks. Reading the wall clock does not grant permission to set it. Profiler statistics, console output, counters and markers use separate rights interpreted against a profiler target.

`procStats` writes into a validated user buffer. Its structures are shared definitions in `ReixABI`, not arbitrary pointers into kernel state. See [ABI boundaries](../../ABI/README.md).

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 2 | [`putchar`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIO/PutcharSyscall.swift) | `x0`: byte value, truncated to `UInt8` | No result value promised; emits a kernel-console byte. |
| 33 | [`profileControl`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/Profile/ProfileControlSyscall.swift) | `x0`: `ProfileOperation`; `x1`: operation argument; `x2`: authority handle | `x0`: operation-specific result. Most controls use 0/1 success/failure; the PMU probe returns a capability mask. |
| 34 | [`procStats`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/Profile/ProcStatsSyscall.swift) | `x0`: `StatsSubOperation`; `x1`: traversal cursor; `x2`: output buffer; `x3`: authority handle | `x0`: 0 for a system snapshot; PID of the next process for a process snapshot. `UInt64.max` means failure or end of traversal. |
| 43 | [`clockNow`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTime/ClockNowSyscall.swift) | None | `x0`: wall time in nanoseconds; 0 when the clock has not been set. |
| 44 | [`clockSet`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTime/ClockSetSyscall.swift) | `x0`: wall-time nanoseconds; `x1`: clock-authority handle | `x0`: 0 on success; `UInt64.max` on failure. |
| 46 | [`powerOff`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTime/PowerOffSyscall.swift) | `x0`: power-authority handle | Does not return on successful power-off; `UInt64.max` if denied or unsupported. |

## Statistics sub-operations

| `x0` input | Output buffer at `x2` | Successful `x0` result |
| --- | --- | --- |
| 0 / `systemOperation` | `SystemStats` | 0. |
| 1 / `processOperation` | `ProcessStats` | PID of the successor after the `x1` cursor; feed it into the next request. |

The process traversal uses `UInt64.max` for both exhaustion and failure. System metric availability bits distinguish a measured zero from an unavailable metric.

## Userland API

[Time](../../../Sources/Reix/Time), [profiler support](../../../Sources/Reix/Profile) and [PMU access](../../../Sources/Reix/PMU.swift) provide the userland wrappers. Operation-specific layouts and masks live in [ReixABI](../../../Sources/ReixABI).
