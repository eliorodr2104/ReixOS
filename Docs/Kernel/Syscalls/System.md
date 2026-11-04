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

### `SystemStats`

164 bytes, stride 168, alignment 8; members aligned in declaration order. [SystemStats](../../../Sources/ABI/Stats/SystemStats.swift#L42) defines the record and [ABILayoutTests.statsLayout](../../../Tests/ABILayoutTests/ABILayoutTests.swift#L225) checks its size, stride and every field offset. A group whose `availability` bit is clear reads zero and means "not measured".

| Offset | Fields | Type | Group / meaning |
| --- | --- | --- | --- |
| 0, 8, 16 | `physicalTotalPages`, `physicalAllocatedPages`, `physicalFreePages` | `UInt64` | Physical frames, machine-wide. |
| 24, 28 | `physicalQuarantinedPages`, `physicalQuarantinedRegions` | `UInt32` | DMA buffers nobody holds, kept out of the page manager until their device is declared reset. Counted as allocated. |
| 32 | `physicalRefusedPages` | `UInt32` | Frames of quarantined DMA blocks whose reclaim the page manager refused; held until its books make sense. Counted as allocated. |
| 36 | `physicalDoubleFrees` | `UInt32` | DMA blocks found already free at reclaim. |
| 40, 48, 56, 64 | `kernelHeapLiveBytes`, `kernelHeapLiveHighWaterBytes`, `kernelHeapReservedBytes`, `kernelHeapReservedHighWaterBytes` | `UInt64` | Kernel heap: rounded live capacity and physical backing. |
| 72 | `timerFrequency` | `UInt64` | Generic-timer Hz; the unit of every latency field. |
| 80 | `traceLost` | `UInt64` | Trace events dropped. |
| 88 | `availability` | `UInt32` | `SystemMetricAvailability` bits: physical memory, kernel heap, stacks, timer, PMU cycle counter, latency (`1 << 5`). |
| 92, 96, 100, 104 | `kernelStackUsedBytes`, `kernelStackCapacity`, `exceptionStackUsedBytes`, `exceptionStackCapacity` | `UInt32` | Stack high-water marks from the poison scan. |
| 108, 110 | `pmuEventAvailability`, `pmuEventCounters` | `UInt16` | PMU events advertised and counters implemented. |
| 112 | `wakeToRunLongest` | `UInt32` | Worst wake-to-run, counter units, saturated. |
| 116 | `deadlineLagLongest` | `UInt32` | Worst lag from a kernel deadline to its process running. |
| 120, 124 | `irqOffLongest`, `irqOffLongestPath` | `UInt32` | Longest IRQ-off stretch and its `IrqOffPath`: a syscall number below 64, 64 for an interrupt, 65 for any other exception. |
| 128, 132, 136, 140, 144, 148 | `irqOffCloneLongest`, `irqOffUnmapLongest`, `irqOffDecommitLongest`, `irqOffTeardownLongest`, `irqOffRollbackLongest`, `irqOffTaskMapLongest` | `UInt32` | Longest stretch inside each named preemption region. |
| 152 | `irqOffProfileLongest` | `UInt32` | Longest stretch on the `profileControl` syscall path. |
| 156 | `irqOffTraceDumpLongest` | `UInt32` | Longest stretch inside `TraceConsoleDump`. |
| 160 | `irqOffCreateLongest` | `UInt32` | Longest stretch inside `ProcessCreation`. |

[StatsExportPage](../../../Sources/ABI/Stats/SystemStats.swift#L125) derives the shared-page offsets from the stride: `SystemStats` starts at byte 8, process count at 176 and process slots at 184. Readers validate both the seqlock and the attachment generation. Event consumers acknowledge a cursor and generation together, so a reader resumed after replacement cannot acknowledge the new attachment, even when its physical page is reused.

The latency fields are described in [Scheduling](../Scheduling.md#latency-measurement).

## Userland API

[Time](../../../Sources/SDK/Time), [profiler support](../../../Sources/SDK/Profile) and [PMU access](../../../Sources/SDK/Profile/PMU.swift) provide the userland wrappers. Operation-specific layouts and masks live in [ReixABI](../../../Sources/ABI).
