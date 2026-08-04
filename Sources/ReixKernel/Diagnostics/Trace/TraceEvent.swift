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
/// host decoder hardcodes that mapping. See `TraceCode` for the table.
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
    /// - Note: `ProcessManager.pidCounter` starts at zero, so `Init` shares that
    ///   value and the field alone cannot tell the two apart. The scheduler's
    ///   `idleEnter` and `idleExit` records are what disambiguate a stretch of
    ///   zeros, and a truncated 64-bit pid would collide the same way; both are
    ///   the contract's, not this field's, to change.
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


/// The event vocabulary, `class << 8 | operation`.
///
/// These are wire constants: the host decoder hardcodes both the numbers and
/// the meaning of `info`, `a` and `b` under each of them. Add codes, never
/// renumber one.
enum TraceCode {

    /// One record per dispatched syscall, written once the dispatch has
    /// returned. `info` = `SyscallNumber` raw, `a` = the duration in counter
    /// units, `b` = the `x0` the syscall is handing back. Entry time is
    /// `timestamp - a`, so one record carries the whole span.
    static let syscallExit: UInt16 = 0x0100

    /// `a` = outgoing pid, `b` = incoming pid.
    static let ctxSwitch: UInt16 = 0x0200

    /// The ready queue came up empty with somebody still running.
    static let idleEnter: UInt16 = 0x0201

    /// The first task picked after an idle stretch.
    static let idleExit: UInt16 = 0x0202

    /// A process parked on an endpoint. `info` = `TraceBlockReason`,
    /// `a` = endpoint id.
    static let ipcBlock: UInt16 = 0x0300

    /// `a` = the pid put back on the ready queue.
    static let ipcWake: UInt16 = 0x0301

    /// A message crossed. `a` = sender pid, `b` = receiver pid.
    static let ipcTransfer: UInt16 = 0x0302

    /// One per `Preemption.run` that owned its window. `info` = the region's
    /// slot, `a` = the longest the door stayed shut in that run, `b` = the
    /// checkpoints it opened.
    static let preemptSpan: UInt16 = 0x0400

    /// `info` = `TraceBootPhase`.
    static let bootPhase: UInt16 = 0x0700

    /// `a` = the new pid, `b` = the pid that asked for it.
    static let procSpawn: UInt16 = 0x0800

    /// `info` = the exit reason, `a` = the pid that died.
    static let procExit: UInt16 = 0x0802
}


/// Why a process parked, carried in `TraceCode.ipcBlock`'s `info`.
enum TraceBlockReason {

    /// `send` found no receiver waiting and queued the sender.
    static let sendQueue: UInt16 = 0

    /// `receive` found no message and queued the receiver.
    static let recvWait: UInt16 = 1

    /// `call` parked its caller, either behind the send queue or on the reply.
    static let call: UInt16 = 2
}


/// Which subsystem had just finished coming up, carried in
/// `TraceCode.bootPhase`'s `info`.
///
/// The ids are the host decoder's name table, so they are fixed independently
/// of `Kernel.boot`'s statement order: a phase that stops existing leaves a gap
/// rather than renumbering the ones after it.
enum TraceBootPhase {

    static let ppmReady    : UInt16 = 1
    static let vmmReady    : UInt16 = 2
    static let heapReady   : UInt16 = 3
    static let gicReady    : UInt16 = 4
    static let fsReady     : UInt16 = 5
    static let pmReady     : UInt16 = 6
    static let schedReady  : UInt16 = 7
    static let ipcReady    : UInt16 = 8
    static let syscallReady: UInt16 = 9
    static let timerOn     : UInt16 = 10

    /// The last kernel statement before `eret` into EL0.
    static let firstUser: UInt16 = 11
}
