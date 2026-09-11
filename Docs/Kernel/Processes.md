# Processes and controlled launch

[Documentation home](../README.md) · [System map](../Architecture/System.md)

## Process ownership and lifetime

`Process` is the current scheduling and address-space unit. It contains the saved CPU context, run state, accounting and IPC wait state. `ProcessMetadata` holds capabilities and colder lifecycle information. There is no separate implemented native-thread/TCB abstraction yet.

`ProcessManager` creates processes, releases address spaces, terminates processes and maintains the process-statistics index. Family links track parents and children; scheduler links track queue membership. Those are separate relationships even though they share one process record.

### Important fields

| Field | Type | Meaning |
| --- | --- | --- |
| `pid` | `PID` (`UInt64`) | Process identifier. |
| `identity` | `Identity` (`UInt32`) | Principal identifier used by IPC and ownership checks. |
| `context` | `UnsafeMutablePointer<Arch.TrapFrame>?` | Saved execution frame. |
| `status` | `ProcessStatus` | New, runnable, running, waiting, IPC-blocked or terminated. |
| `addressSpace` | `AddressSpace` | User translations and VMAs. |
| `metadata` | `UnsafeMutablePointer<ProcessMetadata>!` | Capability table, image metadata, name and exit information. |
| `cpuTime`, `scheduledAt` | `UInt64` | Closed CPU slices and the counter value at the start of an open slice. |
| `pending` | `PendingMessage?` | Pending IPC state. |
| `family` | `ProcessRelations` | Parent and child links. |
| `kernelDeadline*` | Deadline, order, index and kind | Membership in the shared deadline queue. |

### Creation and termination

The kernel still contains a bootstrap path that loads a named ELF from the embedded tar archive. The suspended-task path instead creates an empty process for a userland loader. Both exist in the current checkout; [ProcessServer](../Userland/ProcessLaunch.md) handles the ordinary disk-backed application path.

Termination removes scheduling and IPC participation and releases resources according to the process/task lifecycle. An exit status can outlive an address space until the relevant parent or job observer consumes it. Kernel cleanup and userland supervision are different responsibilities.

`ProcessStatsIndex` maintains an intrusive AVL index for bounded traversal. It is not the scheduler's ready queue. See [Task control](Processes.md) for generation-checked handles and [Scheduling](Scheduling.md) for execution.

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>ProcessManager.spawnProcess(path:)</code>](../../Sources/ReixKernel/Process/ProcessManager.swift#L112) | <code>path: UnsafePointer&lt;CChar&gt;</code> | <code>UnsafeMutablePointer&lt;Process&gt;; throws(ProcessManagerError)</code> | Loads an initrd ELF and returns a process pointer, or throws a process-manager error. |
| [<code>ProcessManager.spawnProcess(name:nameLength:)</code>](../../Sources/ReixKernel/Process/ProcessManager.swift#L257) | <code>name : InlineArray&lt;16, UInt8&gt;? = nil, nameLength: Int = 0</code> | <code>UnsafeMutablePointer&lt;Process&gt;; throws(ProcessManagerError)</code> | Creates an empty process record/address space for controlled configuration. |
| [<code>ProcessManager.killProcess(_:reason:context:)</code>](../../Sources/ReixKernel/Process/ProcessManager.swift#L483) | <code>_ process: UnsafeMutablePointer&lt;Process&gt;, reason : ExitReason, context: SyscallContext</code> | <code>Bool</code> | Attempts termination of the selected process and reports success. |
| [<code>ProcessManager.isAlive(identity:)</code>](../../Sources/ReixKernel/Process/ProcessManager.swift#L618) | <code>identity: Identity</code> | <code>Bool</code> | Reports whether that principal is still alive. |
| [<code>Process.takePending()</code>](../../Sources/ReixKernel/Process/Process.swift#L159) | <code>—</code> | <code>PendingMessage?</code> | Returns and clears the pending IPC message. |

## Configuring a task before execution

The task-control API lets a userland loader construct a process before it can run. A generation-checked `TaskControl` names a record in `TaskRegistry`; the capability target determines whether the holder can configure a suspended task or control an existing job.

### Lifecycle

```mermaid
stateDiagram-v2
    [*] --> configuring: taskCreate
    configuring --> configuring: map / write / seal / set context
    configuring --> running: taskStart
    configuring --> aborted: taskAbort
    running --> exited: exit / termination
```

Starting requires a complete, valid configuration. Mapping bounds, write ranges, permissions, entry point, stack and program break are checked before scheduling. Configuration uses separate map, copy and seal operations rather than allowing the loader to modify arbitrary running address spaces.

### Record and limits

| State | Type / limit | Purpose |
| --- | --- | --- |
| `TaskControl.slot` | `UInt8` | Registry slot. |
| `TaskControl.generation` | `UInt32` | Distinguishes reused slots. |
| Registry | 32 records | Fixed current capacity. |
| `TaskRecord.owner` | `Identity` | Principal responsible for configuration. |
| `TaskRecord.process` | `UnsafeMutablePointer<Process>?` | Live process, when present. |
| Regions | Up to 32 per task | Checked configuration regions and their sealed state. |
| `contextSet` | `Bool` | Whether a valid initial context has been installed. |
| `capabilityReferences` | `UInt16` | References from task/job capabilities. |
| One mapping request | Up to 1024 pages | `TaskABI.maximumPagesPerMapping`. |
| One write request | Up to 64 KiB | `TaskABI.maximumWriteBytes`. |

These limits describe today's implementation. The dynamic TCB budget in [Concurrency](../Concurrency.md) is a future design and does not change this registry.

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>ProcessManager.createSuspendedTask(ownedBy:name:nameLength:)</code>](../../Sources/ReixKernel/Process/ProcessManager+Tasks.swift#L12) | <code>ownedBy owner: UnsafeMutablePointer&lt;Process&gt;, name : InlineArray&lt;16, UInt8&gt;? = nil, nameLength : Int = 0</code> | <code>(control: TaskControl, process: UnsafeMutablePointer&lt;Process&gt;)?</code> | Returns the control token and process, or `nil` if creation cannot complete. |
| [<code>ProcessManager.mapTaskAnonymous(_:at:pages:)</code>](../../Sources/ReixKernel/Process/ProcessManager+Tasks.swift#L35) | <code>_ control : TaskControl, at address: VirtualAddress, pages : UInt32</code> | <code>TaskResult</code> | Creates a checked anonymous configuration region; returns a typed status. |
| [<code>ProcessManager.writeTask(_:at:from:count:)</code>](../../Sources/ReixKernel/Process/ProcessManager+Tasks.swift#L115) | <code>_ control : TaskControl, at address : VirtualAddress, from source: VirtualAddress, count : UInt64</code> | <code>TaskResult</code> | Copies bytes from the caller into a writable configuration region. |
| [<code>ProcessManager.sealTaskRegion(_:at:pages:permissions:)</code>](../../Sources/ReixKernel/Process/ProcessManager+Tasks.swift#L176) | <code>_ control : TaskControl, at address : VirtualAddress, pages : UInt32, permissions: TaskMemoryPermissions</code> | <code>TaskResult</code> | Finalizes a region’s protection and rejects conflicting permissions. |
| [<code>ProcessManager.startTask(_:context:)</code>](../../Sources/ReixKernel/Process/ProcessManager+Tasks.swift#L258) | <code>_ control: TaskControl, context : SyscallContext</code> | <code>TaskStartResult</code> | Transitions a fully configured task into execution and reports its result. |
| [<code>ProcessManager.taskStatus(_:)</code>](../../Sources/ReixKernel/Process/ProcessManager+Tasks.swift#L319) | <code>_ control: TaskControl</code> | <code>TaskStatus</code> | Returns the task state and exit information represented by the control token. |
