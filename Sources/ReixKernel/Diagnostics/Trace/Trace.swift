//
//  Trace.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//


/// The one funnel every trace record goes through.
///
/// Nothing here prints. Records land in `TraceRing` and stay there until
/// `profileControl(.dumpConsole)` walks them out, which is what keeps the boot
/// log a byte-for-byte regression baseline while the ring is filling.
enum Trace {

    /// Which classes are recording right now, one bit per `TraceCategory`.
    ///
    /// The event classes are on at reset, so a kernel that is never told
    /// anything still has the last 256 events when something goes wrong.
    /// Sampling and PMU sections start off: both are volume producers that
    /// exist to be switched on for a measurement, not to run ambiently.
    /// `profileControl` moves this, and a class whose bit is clear costs one
    /// load, one `tst` and a branch at each of its sites.
    static var runtimeMask: UInt32 = 0x3F


    /// Files one record for `category`, if that class is recording.
    ///
    /// The stamp is deliberately the *unordered* counter read: an event is a
    /// point in time and not the end of a measured region, so there is nothing
    /// for an `isb` to keep on the right side of it, and paying a pipeline
    /// flush per event would make the ring cost more than the thing it watches.
    /// Durations are measured with `stamp()`, which is the ordered read.
    ///
    /// A `nil` current process stamps `pid` zero, which the kernel and the idle
    /// loop both legitimately are. `pid` overrides that attribution for the
    /// few records that describe a process other than the caller, `procName`
    /// being the one today.
    @inline(__always)
    static func emit<C: TraceCategory>(
        _    category: C.Type,
        code         : UInt16,
        info         : UInt16  = 0,
        a            : UInt64  = 0,
        b            : UInt64  = 0,
        pid          : UInt32? = nil
    ) {
        guard C.isEnabled              else { return }
        guard runtimeMask & C.bit != 0 else { return }

        let stamped = pid ?? UInt32(
            truncatingIfNeeded: Arch.CPU.getCurrentProcess()?.pointee.pid ?? 0
        )

        TraceRing.append(TraceEvent(
            timestamp: Arch.Timer.counterUnordered(),
            code     : code,
            info     : info,
            pid      : stamped,
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
        _     category : C.Type,
        info           : UInt16,
        frame          : UnsafeMutablePointer<Arch.TrapFrame>,
        _     dispatch : () -> Void
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
