# Process and task syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

These operations either act on the current process, use a parent/child relationship, or require task/job capabilities. `spawnProcess` remains the initrd bootstrap loader. The `task*` family is the kernel mechanism used by the userland application loader.

Task configuration is described in [Processes](../Processes.md); the launch protocol is described in [ProcessServer](../../Userland/ProcessLaunch.md).

A task handle is a process-local `UInt32` capability index. `TaskResult` is a `UInt64` enum: `ok = 0`, `invalidCapability = 1`, `invalidState = 2`, `invalidRange = 3`, `permissionConflict = 4`, `outOfMemory = 5`, `full = 6`, `malformed = 7`. `TaskState` values are `invalid = 0`, `configuring = 1`, `running = 2`, `exited = 3`, `aborted = 4`.

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 0 | [`exit`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/ExitSyscall.swift) | `x0`: exit code | Does not return to the exiting process. |
| 1 | [`yield`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/YieldSyscall.swift) | None | No value promised; requests another scheduling opportunity. |
| 3 | [`getPid`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/GetPIDSyscall.swift) | None | `x0`: current PID (`UInt64`); 0 when no current process exists. |
| 4 | [`getParentPid`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/GetParentPIDSyscall.swift) | None | `x0`: parent PID; 0 when no parent is available. |
| 5 | [`parentEndpoint`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/GetParentEndpointSyscall.swift) | None | `x0`: parent endpoint handle; `UInt32.max` when absent. |
| 6 | [`spawnProcess`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/SpawnProcessSyscall.swift) | `x0`: path pointer; `x1`: byte length; `x2`: `CapGrant` array pointer; `x3`: grant count | `x0`: PID; `x1`: parent-side endpoint. Failure: `UInt64.max`, `UInt32.max`. A zero path selects the empty-process branch. |
| 7 | [`split`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/SplitProcessSyscall.swift) | None | `x0`: child PID in the parent; 0 in the child; `UInt64.max` on failure. |
| 8 | [`reapChild`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/ReapChildSyscall.swift) | `x0`: child PID | `x0`: `ExitCode`; may wait for a live child. Invalid/non-child paths return 0, which is also a valid exit code. |
| 9 | [`sleep`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/SleepSyscall.swift) | `x0`: duration in scheduler ticks | `x0`: 0 on completed/zero wait; 1 on failure. One tick is 10 ms. |
| 10 | [`terminate`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TerminateSyscall.swift) | `x0`: child PID | `x0`: 0 on success; `UInt64.max` if the child cannot be terminated through this path. |
| 47 | [`identityAlive`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/IdentityAliveSyscall.swift) | `x0`: identity, converted to `UInt32` | `x0`: 1 when alive, otherwise 0. |
| 48 | [`taskCreate`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskCreateSyscall.swift) | `x0`: optional name pointer; `x1`: name byte count; both 0 for unnamed | `x0`: task handle; `x1`: bootstrap endpoint handle. Both are `UInt32.max` on failure. |
| 49 | [`taskMapAnonymous`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskMapAnonymousSyscall.swift) | `x0`: task; `x1`: virtual address; `x2`: page count (`UInt32`) | `x0`: `TaskResult`. |
| 50 | [`taskWrite`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskWriteSyscall.swift) | `x0`: task; `x1`: target virtual address; `x2`: caller buffer; `x3`: byte count | `x0`: `TaskResult`. |
| 51 | [`taskSealAndProtect`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskSealAndProtectSyscall.swift) | `x0`: task; `x1`: virtual address; `x2`: pages; `x3`: `TaskMemoryPermissions` bits | `x0`: `TaskResult`. |
| 52 | [`taskSetContext`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskSetContextSyscall.swift) | `x0`: task; `x1`: entry PC; `x2`: stack pointer; `x3`: program break | `x0`: `TaskResult`. |
| 53 | [`taskStart`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskStartSyscall.swift) | `x0`: task handle | `x0`: `TaskResult`; `x1`: PID, or 0 on failure. The control capability transitions to a job view on success. |
| 54 | [`taskAbort`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskAbortSyscall.swift) | `x0`: task handle | `x0`: `TaskResult`; aborts configuration. |
| 55 | [`taskTerminate`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskTerminateSyscall.swift) | `x0`: job/control handle with termination rights | `x0`: `TaskResult`. |
| 56 | [`taskStatus`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/TaskStatusSyscall.swift) | `x0`: job/control handle with status rights | `x0`: `TaskState`; `x1`: exit code. Invalid authority returns `.invalid`, 0. |

## Userland API

The [task SDK](../../../Sources/Reix/RXTask.swift) translates these operations into `SpawnResult`, `TaskCreation`, `TaskResult`, `TaskStartResult` and `TaskStatus`. The wrappers `jobCancel` and `jobStatus` use the raw `taskTerminate` and `taskStatus` numbers. `waitForJob` is an SDK polling loop, not another syscall. `sleep(for:)` converts milliseconds/seconds into ticks, rounding milliseconds upward.
