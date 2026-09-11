# Scheduling and kernel progress

[Documentation home](../README.md) · [System map](../Architecture/System.md)

## Selecting runnable work

`RoundRobin` selects among ready `Process` records. It maintains ready, waiting and terminated lists and tracks the currently used slice. The configured quantum is **7 ticks**; `SchedulerABI.millisecondsPerTick` is **10 ms**, so the nominal quantum is **70 ms**. Interrupt handling and blocking can change the observed time between dispatches.

A process that blocks on IPC, sleep or another wait leaves the runnable path. Waking it makes it eligible again. A rescheduling request sets `needsResched`; frame replacement happens at the exception-return boundary.

### Scheduler state

| Member | Type | Meaning |
| --- | --- | --- |
| `ready`, `waiting`, `terminated` | `LinkedList<Process>` | Intrusive process queues. |
| `currentTicks` | `UInt` | Tick count in the active slice. |
| `quantum` | `UInt` | Slice limit, currently 7. |
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
| [<code>RoundRobin.addTask(_:)</code>](../../Sources/ReixKernel/Scheduler/RoundRobin.swift#L64) | <code>_ process: UnsafeMutablePointer&lt;Process&gt;</code> | <code>Void; throws(SchedulerError)</code> | Adds a newly created process to the runnable queue; rejects an invalid starting state. |
| [<code>RoundRobin.selectNextTask()</code>](../../Sources/ReixKernel/Scheduler/RoundRobin.swift#L114) | <code>—</code> | <code>UnsafeMutablePointer&lt;Process&gt;?</code> | Returns the next process to run, or `nil` when no process is runnable. |
| [<code>RoundRobin.onTick()</code>](../../Sources/ReixKernel/Scheduler/RoundRobin.swift#L213) | <code>—</code> | <code>Bool</code> | Increments the tick counters; returns `true` when the active slice has reached its quantum. |
| [<code>KernelDeadlineQueue.arm(_:kind:deadline:)</code>](../../Sources/ReixKernel/Scheduler/KernelDeadlineQueue.swift#L31) | <code>_ process : UnsafeMutablePointer&lt;Process&gt;, kind : KernelDeadlineKind, deadline: UInt64</code> | <code>Bool</code> | Arms the process deadline; reports whether insertion succeeded. |
| [<code>KernelDeadlineQueue.poll(now:budget:_:)</code>](../../Sources/ReixKernel/Scheduler/KernelDeadlineQueue.swift#L73) | <code>now : UInt64, budget: Int, _ body : (UnsafeMutablePointer&lt;Process&gt;, KernelDeadlineKind) -&gt; Void</code> | <code>Int</code> | Processes up to the supplied number of due entries and returns the count. |

## Keeping long operations interruptible

Long memory operations use explicit work objects implementing `ResumableOperation`. Each call to `step()` performs a bounded part of the operation. `Preemption.run` checks elapsed counter time between steps and may briefly enable interrupts.

### Modes

| Mode | Behavior | Used for |
| --- | --- | --- |
| `latencyOnly` | Service pending interrupts, then finish the operation. | Cleanup paths such as teardown and rollback. |
| `rescheduling` | Service interrupts and return the remaining work when a reschedule is pending. | Operations whose caller can preserve progress and retry. |

`PreemptionOutcome` is either `.completed` or `.suspended(Operation)`. The latter contains the unfinished work value. The caller is responsible for keeping that value and arranging a later step; it is not a userland task or a saved kernel stack.

### Policy and accounting

`PreemptionRegion` supplies a static slot, name, enabled flag, mode and `CheckpointPolicy`. The policy contains `stepsPerProbe: UInt32` and a microsecond `budget: UInt32`. The current memory-region policies use a 200 μs budget with a probe after each step. This is a target checked between work batches, not a hard bound on interrupt latency.

Only the outer active driver owns interrupt windows. The driver avoids opening one while `LogRing` is recording. `PreemptionSpans` aggregates checkpoint and stretch measurements for diagnostics.

This internal mechanism is already present. The proposed userland M:N runtime in [Concurrency](../Concurrency.md) is a separate layer.

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>Preemption.run(_:_:)</code>](../../Sources/ReixKernel/Preemption/Preemption.swift#L143) | <code>_ region : Region.Type, _ operation: consuming Operation</code> | <code>PreemptionOutcome&lt;Operation&gt;; throws(Operation.Failure)</code> | Runs steps to completion or returns the unfinished operation; propagates its typed failure. |
