# Scheduling and kernel progress

[Documentation home](../README.md) · [System map](../Architecture/System.md)

## Selecting runnable work

`RoundRobin` selects among ready `Process` records. It maintains ready, waiting and terminated lists. The quantum is **7 ticks**; `SchedulerABI.millisecondsPerTick` is **10 ms**, so the nominal quantum is **70 ms**. Each process carries its own remainder in `Process.quantumLeft`: a tick spends only the running process's, a block keeps it and a yield gives it up.

A process that blocks on IPC, sleep or another wait leaves the runnable path. `makeReady` is the one place a wake decides where it goes:

- **Quantum left:** the process goes to the front of the ready queue and requests a switch. Several wakes before one switch run in the order they came (`lastWoken`). The process they preempt goes back behind them and keeps its remainder.
- **Quantum spent:** the process gets a fresh quantum and joins the tail, as an expiry does, without requesting a switch.

Only the tail refills a quantum, and nothing at the tail overtakes a process already queued. A ready process therefore waits at most the sum of every other process's remainder, `(n - 1) × 7` ticks for `n` processes, however often the others wake each other. A rescheduling request sets `needsResched`; frame replacement happens at the exception-return boundary.

Lending a caller's remainder to the process it wakes is planned, not implemented. It would move `quantumLeft` from one process to the other inside `makeReady`, so it would keep the bound above.

### Scheduler state

| Member | Type | Meaning |
| --- | --- | --- |
| `ready`, `waiting`, `terminated` | `LinkedList<Process>` | Intrusive process queues. |
| `quantum` | `UInt8` (static) | Slice length, currently 7 ticks. |
| `Process.quantumLeft` | `UInt8` | Ticks left in the process's slice; carried across a block and a wake. |
| `lastWoken` | `UnsafeMutablePointer<Process>?` | Last process a wake put at the front since the previous rotation. |
| `needsResched` | `Bool` | A switch is pending. |
| `isIdle`, `idleSince`, `idleTime` | `Bool`, `UInt64`, `UInt64` | Track time with no runnable work. |
| `systemTicks` | `UInt64` | System tick accounting. |

### Shared deadline queue

`KernelDeadlineQueue` holds up to **1024** entries and uses process-embedded membership metadata. Its normal tick processing budget is **8** expired entries per poll. Sleeping processes, IPC receive timeouts and IRQ waits share this mechanism; queue capacity and per-tick service budget are explicit bounds.

`SleepDeadlineIndex` provides the sleep-specific interface. Deadline cancellation is part of waking or unlinking a waiter, so a completed wait must not remain armed.

The current scheduler is a single global instance. Separate native threads, multiple run queues and an M:N runtime are future work described in [Concurrency](../Concurrency.md).

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>RoundRobin.addTask(_:)</code>](../../Sources/ReixKernel/Scheduler/RoundRobin.swift#L74) | <code>_ process: UnsafeMutablePointer&lt;Process&gt;</code> | <code>Void; throws(SchedulerError)</code> | Adds a newly created process to the runnable queue; rejects an invalid starting state. |
| [<code>RoundRobin.selectNextTask()</code>](../../Sources/ReixKernel/Scheduler/RoundRobin.swift#L135) | <code>—</code> | <code>UnsafeMutablePointer&lt;Process&gt;?</code> | Returns the next process to run, or `nil` when no process is runnable. |
| [<code>RoundRobin.onTick()</code>](../../Sources/ReixKernel/Scheduler/RoundRobin.swift#L312) | <code>—</code> | <code>Bool</code> | Spends one tick of the running process's quantum; returns `true` when it is gone, and on every tick while idle. |
| [<code>KernelDeadlineQueue.arm(_:kind:deadline:)</code>](../../Sources/ReixKernel/Scheduler/KernelDeadlineQueue.swift#L31) | <code>_ process : UnsafeMutablePointer&lt;Process&gt;, kind : KernelDeadlineKind, deadline: UInt64</code> | <code>Bool</code> | Arms the process deadline; reports whether insertion succeeded. |
| [<code>KernelDeadlineQueue.poll(now:budget:_:)</code>](../../Sources/ReixKernel/Scheduler/KernelDeadlineQueue.swift#L73) | <code>now : UInt64, budget: Int, _ body : (UnsafeMutablePointer&lt;Process&gt;, KernelDeadlineKind, UInt64) -&gt; Void</code> | <code>Int</code> | Processes up to the supplied number of due entries and returns the count. The body also receives the expired deadline, for measuring lag. |

## Keeping long operations interruptible

Long memory operations use explicit work objects implementing `ResumableOperation`. Each call to `step()` performs a bounded part of the operation. `Preemption.run` checks elapsed counter time between steps and may briefly enable interrupts.

### Modes

| Mode | Behavior | Used for |
| --- | --- | --- |
| `latencyOnly` | Service pending interrupts, then finish the operation. | Cleanup paths such as teardown and rollback. |
| `rescheduling` | Service interrupts and return the remaining work when a reschedule is pending. | Operations whose caller can preserve progress and retry. |

`PreemptionOutcome` is either `.completed` or `.suspended(Operation)`. The latter contains the unfinished work value. The caller is responsible for keeping that value and arranging a later step; it is not a userland task or a saved kernel stack.

### Policy and accounting

`PreemptionRegion` supplies a static slot, name, enabled flag, mode and `CheckpointPolicy`. The policy contains `stepsPerProbe: UInt32` and a microsecond `budget: UInt32`. Every region uses a 200 μs budget with a probe after each step. This is a target checked between work batches, not a hard bound on interrupt latency.

The budget counts from when the exception masked interrupts, not from when the run started (`IrqOffStretch.elapsed`). A run behind a long prologue therefore opens its first window at its first probe. Outside an exception it falls back to the run's own time.

| Slot | Region | Name | Mode | Covers |
| --- | --- | --- | --- | --- |
| 0 | `AddressSpaceClone` | `[CLON]` | `latencyOnly` | Address-space clone. |
| 1 | `RegionUnmap` | `[UNMP]` | `rescheduling` | `munmap` retirement. |
| 2 | `RegionDecommit` | `[DCMT]` | `rescheduling` | Decommit. |
| 3 | `AddressSpaceTeardown` | `[TDWN]` | `latencyOnly` | Address-space teardown, then the dying process's capabilities, one held slot per step. |
| 4 | `RegionUnmapRollback` | `[RBCK]` | `latencyOnly` | Rollback of a refused unmap. |
| 5 | `TaskMapAnonymous` | `[TMAP]` | `latencyOnly` | `mapTaskAnonymous`, one page per step: charge, allocate, zero and install. |

Only the outer active driver owns interrupt windows. The driver avoids opening one while `LogRing` is recording. `PreemptionSpans` aggregates checkpoint and stretch measurements for diagnostics.

This internal mechanism is already present. The proposed userland M:N runtime in [Concurrency](../Concurrency.md) is a separate layer.

## Latency measurement

The kernel keeps three worst cases, in raw counter units. `procStats` publishes them in `SystemStats` (see [System syscalls](Syscalls/System.md)), and each one also files a trace record.

| Measure | From → to | Trace record |
| --- | --- | --- |
| Wake to run | A process made ready by an event → it is on the CPU. | `wakeRun` (0x0203), one per rotation that runs a woken process. |
| Deadline lag | The instant a kernel deadline was due → its process is on the CPU. The tick handler reads the instant from the timer's compare value, before the rearm. | `deadlineLag` (0x0204). |
| IRQ-off stretch | Exception entry → `eret`, per path: syscall number, interrupt or other exception. A preemption window splits the stretch. | `irqOff` (0x0401), filed only when a path's own worst grows. |

The figures are kept in static variables, which is correct on one core. With SMP they become per-CPU state.

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>Preemption.run(_:_:)</code>](../../Sources/ReixKernel/Preemption/Preemption.swift#L143) | <code>_ region : Region.Type, _ operation: consuming Operation</code> | <code>PreemptionOutcome&lt;Operation&gt;; throws(Operation.Failure)</code> | Runs steps to completion or returns the unfinished operation; propagates its typed failure. |
