//
//  WakeLatency.swift
//  ReixOS
//

/// How long woken processes waited for the CPU, worst case over the uptime.
///
/// Two measurements that end at the same instant, the rotation that puts the
/// process back on the CPU, and differ only in where they start. A wake starts
/// at the wake. A deadline starts at the instant the deadline was due, which is
/// the timer's compare value and not the moment the tick handler got round to
/// it: a tick held off by a masked stretch, or a deadline left for the next
/// tick by `KernelDeadlineQueue.tickBudget`, is lag the sleeper really suffered.
///
/// Statics and not scheduler fields because `ProcStatsSyscall` reads them from
/// a context that holds the PPM and the heap and nothing else. Raw counter
/// units, for the reason every duration in `SystemStats` is raw.
enum WakeLatency {

    /// The longest a process made ready by an event waited to run.
    private(set) static var longestWake: UInt64 = 0

    /// The longest a process made ready by a deadline ran after it was due.
    private(set) static var longestDeadlineLag: UInt64 = 0


    /// Starts a wake-to-run measurement on a process that has just become
    /// ready because something it waited on happened.
    @inline(__always)
    static func stampWake(_ process: UnsafeMutablePointer<Process>) {
        process.pointee.readySince = Arch.Timer.counterUnordered()
        process.pointee.readyCause = .wake
    }


    /// Moves the start of a just-woken process's measurement back to the
    /// instant its deadline was due, and files it as a deadline.
    ///
    /// Only a process that the expiry really made ready: a wait whose expiry
    /// found it already gone has no run to measure.
    @inline(__always)
    static func backdate(_ process: UnsafeMutablePointer<Process>, to dueAt: UInt64) {
        guard case .ready = process.pointee.status,
              process.pointee.readyCause == .wake
        else { return }

        process.pointee.readySince = dueAt
        process.pointee.readyCause = .deadline
    }


    /// Closes the measurement `process` carries, now that it is running.
    ///
    /// Called with the process already installed as current, so the trace
    /// record is stamped with the pid it is about. A start later than `now`
    /// cannot happen on one core, and reads as zero rather than as a wrap.
    @inline(__always)
    static func settle(_ process: UnsafeMutablePointer<Process>, at now: UInt64) {
        let cause = process.pointee.readyCause

        guard cause != .none else { return }

        process.pointee.readyCause = .none

        let since   = process.pointee.readySince
        let latency = now > since ? now - since : 0

        if case .deadline = cause {
            if latency > longestDeadlineLag { longestDeadlineLag = latency }
            Trace.emit(TraceSched.self, code: TraceCode.deadlineLag, a: latency)

        } else {
            if latency > longestWake { longestWake = latency }
            Trace.emit(TraceSched.self, code: TraceCode.wakeRun, a: latency)
        }
    }


    #if !hasFeature(Embedded)
    /// Host suites share these statics; each starts from zero.
    static func reset() {
        longestWake        = 0
        longestDeadlineLag = 0
    }
    #endif
}
