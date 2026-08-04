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
    
    
    private var currentTicks: UInt = 0 // Tick
    private let quantum     : UInt = 7 // One tick is SchedulerABI.millisecondsPerTick

    /// Whether the last `selectNextTask` found nobody to run.
    ///
    /// The trace's only piece of scheduler state, and it exists for `idleExit`
    /// alone: `idleEnter` is self-limiting, since the first empty rotation
    /// clears the current process and every later one then has nothing to
    /// report, but coming *out* of idle is indistinguishable from an ordinary
    /// rotation without remembering that the machine was idle at all.
    private var isIdle: Bool = false
    
    private(set) var systemTicks: UInt64 = 0

    /// See `SchedulerInterface.needsResched`. Cleared by `selectNextTask`,
    /// so whichever site rotates the queue first also cancels the request.
    public private(set) var needsResched: Bool = false


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
        
        process.pointee.status = .ready
        self.ready.pushBack(process)
    }
    
    
    public mutating func unlink(
        _  process: UnsafeMutablePointer<Process>,
        in status : ProcessStatus
    ) {
        switch status {
                
            case .ready  : ready.remove(element: process)
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
    /// ## The quantum, and why idling looks wasteful but is not
    ///
    /// `currentTicks` counts ticks since the last rotation, not per process, so
    /// a task that never yields is preempted after `quantum` of them and a
    /// workload that yields constantly never reaches it. Measured: this kernel
    /// serves roughly a thousand voluntary rotations per tick under IPC load
    /// and the timer never fires, while two spinning tasks alternate at exactly
    /// 7 ticks with no jitter.
    ///
    /// With nobody ready the count is left *spent* rather than reset, so the
    /// timer asks again on every tick. That looks like busy work and is in fact
    /// the only thing that lifts the CPU out of `wfi`: the ask is what notices
    /// a sleeper has become ready. Resetting it here would idle the machine for
    /// a whole quantum between asks and strand every sleeper for up to that
    /// long.
    public mutating func selectNextTask() -> UnsafeMutablePointer<Process>? {

        needsResched = false

        let previous = Arch.CPU.getCurrentProcess()

        if let currentPtr = previous {
            if case .running = currentPtr.pointee.status {
                currentPtr.pointee.status = .ready
                ready.pushBack(currentPtr)
            }
        }
        
        if let next = ready.popFront() {
            let nextAddr = VirtualAddress(UInt(bitPattern: next))
            Arch.CPU.setCurrentProcess(nextAddr)
            next.pointee.status = .running
                        
            currentTicks = 0

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
        
        // Leave the quantum spent rather than untouched, so the next tick asks
        // again. Keeping the old count would delay the first ask by up to a
        // whole quantum, and that ask is what wakes a sleeper.
        currentTicks = quantum

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

        process.pointee.status = .ready
        ready.pushBack(process)
    }
    
    
    public mutating func onTick() -> Bool {
        currentTicks &+= 1
        systemTicks  &+= 1

        return currentTicks >= quantum
    }


    public mutating func requestReschedule() {
        needsResched = true
    }

    
    public mutating func yield() -> UnsafeMutablePointer<AArch64TrapFrame>? {
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
        
        process.pointee.status = .ready
        ready.pushBack(process)
    }
    
    
    // Get a process pointer, because the handler delete a child process
    public mutating func reapChild(_ child: UnsafeMutablePointer<Process>) -> Bool {
        guard case .terminated = child.pointee.status else {
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
