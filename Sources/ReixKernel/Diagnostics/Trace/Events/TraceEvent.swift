//
//  TraceEvent.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// One fixed-size record in the trace ring.
///
/// Thirty-two bytes, every member naturally aligned in declaration order:
/// 8 + 2 + 2 + 4 + 8 + 8, no padding and no hole. That is what lets the ring
/// store a record with a single struct assignment where `LogRing` has to pack
/// its header a byte at a time: its records are variable length and packed back
/// to back, so a header is almost never aligned, and this kernel is built with
/// strict-align codegen.
///
/// What `info`, `a` and `b` mean is decided by `code` and nothing else, and the
/// host decoder hardcodes that mapping.
struct TraceEvent {

    /// Raw `CNTVCT_EL0` at the moment the record was written.
    ///
    /// Kept unconverted for `PreemptionSpan`'s reason: a division per sample
    /// buys nothing on a path that is meant to be almost free, and the dump
    /// reports `CNTFRQ_EL0` once so the host can do it instead.
    var timestamp: UInt64 = 0

    /// `class << 8 | operation`. See `TraceCode`.
    var code: UInt16 = 0

    /// Per-code discriminant: a syscall number, a block reason, a boot phase,
    /// a preemption slot.
    var info: UInt16 = 0

    /// Who was running when the record was written, truncated to 32 bits.
    ///
    /// Zero when nothing was, which is the kernel before the first task and the
    /// idle loop after one blocks. Every emit site therefore reads a `nil`
    /// current process as a value and never as an error.
    ///
    /// - Note: `ProcessManager.pidCounter` starts at 1, so pid 0 belongs only
    ///   to the kernel and idle context and `Init` cannot share it. The
    ///   scheduler's `idleEnter` and `idleExit` records still disambiguate a
    ///   stretch of zeros between "before the first task" and "idle after
    ///   one blocks", and a truncated 64-bit pid would collide the same way
    ///   across processes; both are the contract's, not this field's, to change.
    var pid: UInt32 = 0

    /// Per-code payload. See `TraceCode`.
    var a: UInt64 = 0
    var b: UInt64 = 0


    init(
        timestamp: UInt64 = 0,
        code     : UInt16 = 0,
        info     : UInt16 = 0,
        pid      : UInt32 = 0,
        a        : UInt64 = 0,
        b        : UInt64 = 0
    ) {
        self.timestamp = timestamp
        self.code      = code
        self.info      = info
        self.pid       = pid
        self.a         = a
        self.b         = b
    }
}
