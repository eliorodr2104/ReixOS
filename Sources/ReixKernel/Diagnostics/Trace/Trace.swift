//
//  Trace.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Which class of event a record belongs to, and therefore whether it is
/// compiled at all.
///
/// One conforming type per class. Static requirements only, and read through a
/// generic parameter, for the reason `PreemptionRegion` gives at length: in
/// Embedded Swift every generic call is specialized, so `isEnabled` and `bit`
/// are `static let`s of one concrete type inside each specialization of `emit`,
/// the `guard` in front of the body is a constant, and a class switched off
/// leaves no counter read, no ring write and no code at the emit site. An
/// `any TraceCategory` would put every requirement behind a witness table and
/// destroy that fold; this kernel has no existential anywhere.
///
/// `isEnabled` is the build-time switch and `Trace.runtimeMask` the run-time
/// one. They are deliberately separate: the mask is what `profileControl` moves
/// while the machine is up, and it cannot bring back a class the image was
/// never built with.
protocol TraceCategory {

    /// Whether this class is compiled in at all.
    static var isEnabled: Bool { get }

    /// This class's bit in `Trace.runtimeMask`.
    static var bit: UInt32 { get }
}


/// Syscall entry and exit spans.
enum TraceSyscalls: TraceCategory {
    static let isEnabled       = true
    static let bit    : UInt32 = 1 << 0
}


/// Context switches and the idle transitions around them.
enum TraceSched: TraceCategory {
    static let isEnabled       = true
    static let bit    : UInt32 = 1 << 1
}


/// Rendezvous blocks, wakes and message transfers.
enum TraceIPC: TraceCategory {
    static let isEnabled       = true
    static let bit    : UInt32 = 1 << 2
}


/// One record per owning `Preemption.run`, carrying the latency it cost.
enum TracePreemption: TraceCategory {
    static let isEnabled       = true
    static let bit    : UInt32 = 1 << 3
}


/// Subsystem bring-up milestones, from the first allocator to the first `eret`
/// into EL0.
enum TraceBoot: TraceCategory {
    static let isEnabled       = true
    static let bit    : UInt32 = 1 << 4
}


/// Process creation and death.
enum TraceProc: TraceCategory {
    static let isEnabled       = true
    static let bit    : UInt32 = 1 << 5
}


/// The one funnel every trace record goes through.
///
/// Nothing here prints. Records land in `TraceRing` and stay there until
/// `profileControl(.dumpConsole)` walks them out, which is what keeps the boot
/// log a byte-for-byte regression baseline while the ring is filling.
enum Trace {

    /// Which classes are recording right now, one bit per `TraceCategory`.
    ///
    /// All on at reset, so a kernel that is never told anything still has the
    /// last 256 events when something goes wrong. `profileControl` narrows it,
    /// and a class whose bit is clear costs one load, one `tst` and a branch at
    /// each of its sites.
    static var runtimeMask: UInt32 = .max


    /// Files one record for `category`, if that class is recording.
    ///
    /// The stamp is deliberately the *unordered* counter read: an event is a
    /// point in time and not the end of a measured region, so there is nothing
    /// for an `isb` to keep on the right side of it, and paying a pipeline
    /// flush per event would make the ring cost more than the thing it watches.
    /// Durations are measured with `stamp()`, which is the ordered read.
    ///
    /// A `nil` current process stamps `pid` zero, which the kernel and the idle
    /// loop both legitimately are.
    @inline(__always)
    static func emit<C: TraceCategory>(
        _  category: C.Type,
        code       : UInt16,
        info       : UInt16 = 0,
        a          : UInt64 = 0,
        b          : UInt64 = 0
    ) {
        guard C.isEnabled             else { return }
        guard runtimeMask & C.bit != 0 else { return }

        let current = Arch.CPU.getCurrentProcess()

        TraceRing.append(TraceEvent(
            timestamp: Arch.Timer.counterUnordered(),
            code     : code,
            info     : info,
            pid      : UInt32(truncatingIfNeeded: current?.pointee.pid ?? 0),
            a        : a,
            b        : b
        ))
    }


    /// Files a bring-up milestone into the side table instead of the ring.
    ///
    /// Boot phases are the oldest events in any trace and therefore the first
    /// the ring evicts; parking them in `TraceRing`'s write-once slots keeps
    /// them dumpable for the whole uptime, and the dump replays them ahead of
    /// the ring so the output stays oldest first.
    @inline(__always)
    static func emitBootPhase(_ phase: UInt16) {
        guard TraceBoot.isEnabled               else { return }
        guard runtimeMask & TraceBoot.bit != 0  else { return }

        TraceRing.recordBootPhase(TraceEvent(
            timestamp: Arch.Timer.counterUnordered(),
            code     : TraceCode.bootPhase,
            info     : phase,
            pid      : 0,
            a        : 0,
            b        : 0
        ))
    }


    /// The ordered counter read, for the two ends of a measured span.
    ///
    /// `Arch.Timer.counter()` leads with an `isb`, which is the whole point:
    /// without it the two stamps around a region of work are free to be
    /// speculated out of it and the duration is a fiction.
    @inline(__always)
    static func stamp() -> UInt64 {
        Arch.Timer.counter()
    }


    /// Runs `dispatch` and files one `syscallExit` for it.
    ///
    /// Generic on the category, and structured so that both counter reads sit
    /// behind the same fold as the record itself: with `C.isEnabled` false,
    /// `recording` is a constant, the ternary collapses to zero, the `guard`
    /// after `dispatch` returns unconditionally and the whole tail is dead code
    /// the optimizer drops. Nothing is left at the call site but the dispatch.
    ///
    /// `dispatch` is called exactly once, on purpose. Testing `recording`
    /// around two separate calls would read better and would let the inliner
    /// paste the syscall switch into the image twice.
    ///
    /// `x0` is read here rather than passed in for the same reason: inside the
    /// fold it disappears with everything else.
    @inline(__always)
    static func syscallSpan<C: TraceCategory>(
        _  category: C.Type,
        info       : UInt16,
        frame      : UnsafeMutablePointer<Arch.TrapFrame>,
        _ dispatch : () -> Void
    ) {
        let recording = C.isEnabled && runtimeMask & C.bit != 0
        let entered   = recording ? stamp() : 0

        dispatch()

        guard recording else { return }

        emit(
            category,
            code: TraceCode.syscallExit,
            info: info,
            a   : stamp() &- entered,
            b   : frame.pointee.x0
        )
    }
}
