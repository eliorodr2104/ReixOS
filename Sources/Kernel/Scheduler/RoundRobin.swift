//
//  RoundRobin.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

import ReixABI

public struct RoundRobin: SchedulerInterface, Loggable {
    
    public static var errorMessageAllocation: StaticString = "Failed to allocate Scheduler on the kernel heap"
    
    public static let nameLog : StaticString = "[SCHD]"
    public static let logLevel: LogLevel     = .info
    
    private var ready     : LinkedList = LinkedList<Process>(head: nil, tail: nil)
    private var waiting   : LinkedList = LinkedList<Process>(head: nil, tail: nil)
    private var terminated: LinkedList = LinkedList<Process>(head: nil, tail: nil)
    
    
    /// Ticks a process may run before it goes behind everybody else. One tick
    /// is `SchedulerABI.millisecondsPerTick`. Kept per process, in
    /// `Process.quantumLeft`, because a wake carries the unspent part along.
    public static let quantum: UInt8 = 7

    /// Whether the last `selectNextTask` found nobody to run.
    ///
    /// The trace's only piece of scheduler state, and it exists for `idleExit`
    /// alone: `idleEnter` is self-limiting, since the first empty rotation
    /// clears the current process and every later one then has nothing to
    /// report, but coming *out* of idle is indistinguishable from an ordinary
    /// rotation without remembering that the machine was idle at all.
    private var isIdle: Bool = false

    /// The counter reading of the rotation that found nobody to run, `0` when
    /// the machine is not idle.
    ///
    /// Kept apart from `isIdle` rather than folded into an optional: this one is
    /// arithmetic the accounting owns and that one is the trace's, and a single
    /// field would tie a measurement to whether a trace class is compiled in.
    private var idleSince: UInt64 = 0

    /// Counter units nobody was on the CPU, closed stretches only.
    ///
    /// The complement of the `cpuTime` of every process: a reader that wants
    /// utilisation needs the denominator, and summing the processes gives only
    /// the numerator. Raw counter units, converted by whoever reports it.
    private(set) var idleTime: UInt64 = 0

    private(set) var systemTicks: UInt64 = 0

    /// See `SchedulerInterface.needsResched`. Cleared by `selectNextTask`,
    /// so whichever site rotates the queue first also cancels the request.
    public private(set) var needsResched: Bool = false

    /// The last process a wake put at the front since the previous rotation.
    ///
    /// The next wake queues behind it, so wakes run in the order they came,
    /// and so does a process those wakes preempt, so the one cut short never
    /// gets back ahead of the ones that cut it. The group it ends always starts
    /// at the head, which is what lets `unlink` step it back to `prev`.
    private var lastWoken: UnsafeMutablePointer<Process>? = nil


    /// Written out rather than left implicit only so the boot line has
    /// somewhere to live. Every queue and counter above still starts from
    /// its own declaration.
    public init() {
        Self.boot("Scheduler ready.")
    }


    public mutating func addTask(_ process: UnsafeMutablePointer<Process>) throws(SchedulerError) {
        guard case .new = process.pointee.status else {
            throw .notNewerProcess
        }
        
        process.pointee.status      = .ready
        process.pointee.quantumLeft = Self.quantum
        self.ready.pushBack(process)
    }
    
    
    public mutating func unlink(
        _  process: UnsafeMutablePointer<Process>,
        in status : ProcessStatus
    ) {
        switch status {
                
            case .ready:
                if process == lastWoken { lastWoken = process.pointee.prev }
                ready.remove(element: process)

            case .waiting: waiting.remove(element: process)
            default      : break
        }
    }
    
    public mutating func addZombie(_ process: UnsafeMutablePointer<Process>) {
        terminated.pushBack(process)
    }
    
    
    /// Rotates the ready queue and returns whoever runs next, or `nil` when
    /// there is nobody to run.
    ///
    /// This is the one funnel every rotation goes through, voluntary or
    /// timer-driven, which is why `needsResched` is cleared here: whichever
    /// site rotates first also cancels any pending request, so a switch cannot
    /// happen twice for one expiry.
    ///
    /// ## Where the outgoing process goes
    ///
    /// A process taken off the CPU with its quantum spent joins the tail with a
    /// fresh one. One taken off with quantum left was cut short by a wake, since
    /// a spent quantum and a yield both leave it at zero, so it goes back to
    /// the front, behind the wakes that preempted it, and keeps what it had
    /// left. Losing its place to every ready process because somebody else woke
    /// up would make the CPU-bound pay for the I/O-bound twice.
    ///
    /// ## The quantum, and why idling looks wasteful but is not
    ///
    /// The quantum is per process and spent only by `onTick`, so a task that
    /// never yields is preempted after `quantum` ticks of its own and a
    /// workload that yields constantly spends almost none. Measured on the
    /// global count this replaced: roughly a thousand voluntary rotations per
    /// tick under IPC load with the timer never firing, and two spinning tasks
    /// alternating at exactly 7 ticks with no jitter.
    ///
    /// With nobody on the CPU `onTick` asks on every tick. That used to be the
    /// only thing that lifted the CPU out of `wfi` for a sleeper; every wake now
    /// asks for its own switch, and the per-tick ask stays as the backstop for
    /// a path that might one day make a process ready without asking.
    public mutating func selectNextTask() -> UnsafeMutablePointer<Process>? {

        needsResched = false

        let now      = Arch.Timer.counter()
        let previous = Arch.CPU.getCurrentProcess()

        var preempted: UnsafeMutablePointer<Process>? = nil

        if let currentPtr = previous {
            if currentPtr.pointee.scheduledAt != 0 {
                currentPtr.pointee.cpuTime    &+= now &- currentPtr.pointee.scheduledAt
                currentPtr.pointee.scheduledAt  = 0
            }

            if case .running = currentPtr.pointee.status {
                currentPtr.pointee.status = .ready

                if currentPtr.pointee.quantumLeft == 0 {
                    currentPtr.pointee.quantumLeft = Self.quantum
                    ready.pushBack(currentPtr)

                } else { preempted = currentPtr }
            }
        }

        // Popped before the preempted one is queued, or it would pop itself. With
        // no wake left to make way for, a kill having unlinked it, it carries on.
        let next = preempted != nil && lastWoken == nil
            ? preempted
            : ready.popFront() ?? preempted

        if let preempted, preempted != next {
            queueAtFront(preempted, popped: next)
        }

        lastWoken = nil

        if let next {

            let nextAddr = VirtualAddress(UInt(bitPattern: next))
            Arch.CPU.setCurrentProcess(nextAddr)
            next.pointee.status      = .running
            next.pointee.scheduledAt = now

            WakeLatency.settle(next, at: now)

            if idleSince != 0 {
                idleTime &+= now &- idleSince
                idleSince = 0
            }

            if isIdle {
                isIdle = false
                Trace.emit(TraceSched.self, code: TraceCode.idleExit)
            }

            // Rotating back onto the same task is not a switch, and would bury
            // the real ones under one runnable process's quantum expiries.
            if previous != next {
                Trace.emit(
                    TraceSched.self,
                    code: TraceCode.ctxSwitch,
                    a   : previous?.pointee.pid ?? 0,
                    b   : next.pointee.pid
                )
            }

            return next
        }

        if previous != nil, idleSince == 0 {
            idleSince = now
        }

        if !isIdle, previous != nil {
            isIdle = true
            Trace.emit(TraceSched.self, code: TraceCode.idleEnter)
        }

        Arch.CPU.setCurrentProcess(0)
        return nil
    }


    /// Puts a parked process back on the ready queue, unlinking it first from
    /// whichever list its status says it is parked on.
    ///
    /// The unlink is the invariant, not a courtesy: `prev`/`next` are one pair
    /// of intrusive links shared by every list, so a `pushBack` while still
    /// chained into `waiting` or an endpoint queue would rewrite them and
    /// corrupt the old list in place. Callers that already popped the process,
    /// which is all of the IPC fast paths, pay two nil checks and nothing else,
    /// because `remove(element:)` is a no-op on an unlinked node.
    public mutating func resume(_ process: UnsafeMutablePointer<Process>) {
        switch process.pointee.status {
            case .ready, .running, .terminated:
                return

            case .waiting:
                waiting.remove(element: process)

            case .blockedOnSend(let endpoint), .blockedOnReceive(let endpoint):
                endpoint?.pointee.queue.remove(element: process)

            default:
                break
        }

        makeReady(process)
    }


    /// Queues a process that has just stopped waiting, the one place a wake
    /// decides where it goes.
    ///
    /// With quantum left it goes to the front and asks for the switch, so a
    /// process that blocks before spending its slice, the I/O-bound one, runs
    /// as soon as whatever woke it gets out of the way. With none left it joins
    /// the tail with a fresh quantum, exactly as an expiry would, and asks
    /// nothing.
    ///
    /// ## Why this cannot starve anybody
    ///
    /// Only the tail refills a quantum, and nothing at the tail gets ahead of a
    /// process already queued. Ticks spent before a ready process runs again are
    /// therefore at most the sum of every other process's remainder at the
    /// moment it became ready, `(n - 1) * quantum` with `n` processes, however
    /// often the others wake each other. `RoundRobinTests` holds a ping-pong pair
    /// to two quanta against a process that never blocks.
    ///
    /// ## Where lending would go
    ///
    /// A caller handing its remainder to the process it wakes is a transfer of
    /// `quantumLeft` from one to the other, right before the test below, with the
    /// lender then spent. It moves ticks instead of minting them, so the sum
    /// above, and the bound with it, survives.
    ///
    /// Several wakes before one switch run in the order they came, see
    /// `lastWoken`.
    private mutating func makeReady(_ process: UnsafeMutablePointer<Process>) {
        process.pointee.status = .ready
        WakeLatency.stampWake(process)

        guard process.pointee.quantumLeft > 0 else {
            process.pointee.quantumLeft = Self.quantum
            ready.pushBack(process)
            return
        }

        queueAtFront(process, popped: nil)
        lastWoken    = process
        needsResched = true
    }


    /// Puts `process` behind the wakes queued since the last rotation, or at
    /// the head when there are none still queued. `popped` is the process the
    /// current rotation took off the head, which is no anchor any more.
    @inline(__always)
    private mutating func queueAtFront(
        _ process: UnsafeMutablePointer<Process>,
        popped   : UnsafeMutablePointer<Process>?
    ) {
        if let anchor = lastWoken, anchor != popped {
            ready.insertAfter(element: process, to: anchor)

        } else if let head = ready.getIterator() {
            ready.insertBefore(element: process, to: head)

        } else { ready.pushBack(process) }
    }
    
    
    /// Spends one tick of the running process's quantum, and asks for a switch
    /// once it is gone. Saturates rather than wraps: ticks can land between the
    /// ask and the switch that answers it, on a long syscall.
    public mutating func onTick() -> Bool {
        systemTicks &+= 1

        guard let current = Arch.CPU.getCurrentProcess() else { return true }

        if current.pointee.quantumLeft > 0 {
            current.pointee.quantumLeft -= 1
        }

        return current.pointee.quantumLeft == 0
    }


    public mutating func requestReschedule() {
        needsResched = true
    }

    
    /// Gives up the CPU. A running caller gives up the rest of its quantum
    /// too, which is what sends it to the tail; one that has just blocked is
    /// not running and keeps its remainder for the wake.
    public mutating func yield() -> UnsafeMutablePointer<AArch64TrapFrame>? {
        if let current = Arch.CPU.getCurrentProcess(), case .running = current.pointee.status {
            current.pointee.quantumLeft = 0
        }

        if let nextProcess = selectNextTask() {
            return nextProcess.pointee.context
        }
        
        return nil
    }
    
    
    /// Blocks the current process. `pid` is kept honest, not decorative:
    /// both callers pass their own pid, and a mismatch throws instead of
    /// silently blocking the wrong process.
    public mutating func block(_ pid: PID) throws(SchedulerError) {

        guard let process = Arch.CPU.getCurrentProcess(),
              process.pointee.pid == pid else {
            throw .processNotExist
        }

        process.pointee.status = .waiting
        waiting.pushBack(process)
    }
    
    
    public mutating func wakeUp(_ pid: PID) throws(SchedulerError) {
        guard let process = waiting.remove(id: pid) else {
            throw .processNotExist
        }
        
        makeReady(process)
    }
    
    
    // Get a process pointer, because the handler delete a child process
    public mutating func reapChild(_ child: UnsafeMutablePointer<Process>) -> Bool {
        guard case .terminated = child.pointee.status,
              terminated.search(id: child.pointee.pid) == child else {
            return false
        }
        
        terminated.remove(element: child)
        return true
    }
    
    
    public func search(
        in queue: QueueType = .ready,
        to pid  : PID
    ) -> UnsafeMutablePointer<Process>? {
        switch queue {
            case .ready     : ready     .search(id: pid)
            case .waiting   : waiting   .search(id: pid)
            case .terminated: terminated.search(id: pid)
        }
    }
    
    


    public func notifyTaskBlocked(_ processID: PID) {

    }
    
    
    public func notifyTaskYielded(_ processID: PID) {
        
    }
    
}
