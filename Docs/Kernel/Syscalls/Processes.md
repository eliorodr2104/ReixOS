# Process and task syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

These operations either act on the current process, use a parent/child relationship, or require task/job capabilities. `spawnProcess` remains the initrd bootstrap loader. The `task*` family is the kernel mechanism used by the userland application loader.

Task configuration is described in [Processes](../Processes.md); the launch protocol is described in [ProcessServer](../../Userland/ProcessLaunch.md).

A task handle is a process-local `UInt32` capability index. `TaskResult` is a `UInt64` enum: `ok = 0`, `invalidCapability = 1`, `invalidState = 2`, `invalidRange = 3`, `permissionConflict = 4`, `outOfMemory = 5`, `full = 6`, `malformed = 7`. `TaskState` values are `invalid = 0`, `configuring = 1`, `running = 2`, `exited = 3`, `aborted = 4`.

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 0 | [`exit`](../../../Sources/Kernel/Syscalls/Tasks/ExitSyscall.swift) | `x0`: exit code | Does not return to the exiting process. |
| 1 | [`yield`](../../../Sources/Kernel/Syscalls/Time/YieldSyscall.swift) | None | No value promised; requests another scheduling opportunity. |
| 3 | [`getPid`](../../../Sources/Kernel/Syscalls/Tasks/GetPIDSyscall.swift) | None | `x0`: current PID (`UInt64`); 0 when no current process exists. |
| 4 | [`getParentPid`](../../../Sources/Kernel/Syscalls/Tasks/GetParentPIDSyscall.swift) | None | `x0`: parent PID; 0 when no parent is available. |
| 5 | [`parentEndpoint`](../../../Sources/Kernel/Syscalls/Tasks/GetParentEndpointSyscall.swift) | None | `x0`: parent endpoint handle; `UInt32.max` when absent. |
| 6 | [`spawnProcess`](../../../Sources/Kernel/Syscalls/Tasks/SpawnProcessSyscall.swift) | `x0`: path pointer; `x1`: byte length; `x2`: `CapGrant` array pointer; `x3`: grant count | `x0`: PID; `x1`: parent-side endpoint. Failure: `UInt64.max`, `UInt32.max`. A zero path selects the empty-process branch. |
| 7 | [`split`](../../../Sources/Kernel/Syscalls/Tasks/SplitProcessSyscall.swift) | None | `x0`: child PID in the parent; 0 in the child; `UInt64.max` on failure. |
| 8 | [`reapChild`](../../../Sources/Kernel/Syscalls/Tasks/ReapChildSyscall.swift) | `x0`: child PID | `x0`: `ExitCode`; may wait for a live child. Invalid/non-child paths return 0, which is also a valid exit code. |
| 9 | [`sleep`](../../../Sources/Kernel/Syscalls/Time/SleepSyscall.swift) | `x0`: duration in scheduler ticks | `x0`: 0 on completed/zero wait; 1 on failure. One tick is 10 ms. |
| 10 | [`terminate`](../../../Sources/Kernel/Syscalls/Tasks/TerminateSyscall.swift) | `x0`: child PID | `x0`: 0 on success; `UInt64.max` if the child cannot be terminated through this path. |
| 47 | [`identityAlive`](../../../Sources/Kernel/Syscalls/Tasks/IdentityAliveSyscall.swift) | `x0`: identity, converted to `UInt32` | `x0`: 1 when alive, otherwise 0. |
| 48 | [`taskCreate`](../../../Sources/Kernel/Syscalls/Tasks/TaskCreateSyscall.swift) | `x0`: optional name pointer; `x1`: name byte count; both 0 for unnamed | `x0`: task handle; `x1`: bootstrap endpoint handle. Both are `UInt32.max` on failure. Charges the caller one frame for the task's construction state, so a caller at its frame limit is refused. |
| 49 | [`taskMapAnonymous`](../../../Sources/Kernel/Syscalls/Tasks/TaskMapAnonymousSyscall.swift) | `x0`: task; `x1`: virtual address; `x2`: page count (`UInt32`) | `x0`: `TaskResult`. |
| 50 | [`taskWrite`](../../../Sources/Kernel/Syscalls/Tasks/TaskWriteSyscall.swift) | `x0`: task; `x1`: target virtual address; `x2`: caller buffer; `x3`: byte count | `x0`: `TaskResult`. |
| 51 | [`taskSealAndProtect`](../../../Sources/Kernel/Syscalls/Tasks/TaskSealAndProtectSyscall.swift) | `x0`: task; `x1`: virtual address; `x2`: pages; `x3`: `TaskMemoryPermissions` bits | `x0`: `TaskResult`. |
| 52 | [`taskSetContext`](../../../Sources/Kernel/Syscalls/Tasks/TaskSetContextSyscall.swift) | `x0`: task; `x1`: entry PC; `x2`: stack pointer; `x3`: program break | `x0`: `TaskResult`. |
| 53 | [`taskStart`](../../../Sources/Kernel/Syscalls/Tasks/TaskStartSyscall.swift) | `x0`: task handle | `x0`: `TaskResult`; `x1`: PID, or 0 on failure. The control capability transitions to a job view on success. |
| 54 | [`taskAbort`](../../../Sources/Kernel/Syscalls/Tasks/TaskAbortSyscall.swift) | `x0`: task handle | `x0`: `TaskResult`; aborts configuration. |
| 55 | [`taskTerminate`](../../../Sources/Kernel/Syscalls/Tasks/TaskTerminateSyscall.swift) | `x0`: job/control handle with termination rights | `x0`: `TaskResult` if the caller survives. Does not return when the job's death takes the caller, directly or through owned tasks. |
| 56 | [`taskStatus`](../../../Sources/Kernel/Syscalls/Tasks/TaskStatusSyscall.swift) | `x0`: job/control handle with status rights | `x0`: `TaskState`; `x1`: exit code. Invalid authority returns `.invalid`, 0. |

## Userland API

The [task SDK](../../../Sources/SDK/Syscalls/RXTask.swift) translates these operations into `SpawnResult`, `TaskCreation`, `TaskResult`, `TaskStartResult` and `TaskStatus`. The wrappers `jobCancel` and `jobStatus` use the raw `taskTerminate` and `taskStatus` numbers. `waitForJob` is an SDK polling loop, not another syscall. `sleep(for:)` converts milliseconds/seconds into ticks, rounding milliseconds upward.
