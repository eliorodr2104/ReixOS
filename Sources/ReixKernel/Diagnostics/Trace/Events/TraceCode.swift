//
//  TraceCode.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.
//


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

    /// One PC sample from the timer tick. `a` = ELR, `b` = x30 at the trap,
    /// `info` bit 0 set when the sample interrupted EL1.
    static let sample: UInt16 = 0x0500

    /// One frame of an EL1 sample's FP chain. `a` = the return address,
    /// `info` = its depth below the sampled PC, starting at 1.
    static let sampleFrame: UInt16 = 0x0501

    /// One measured kernel section. `info` = the section id, `a` = the cycle
    /// delta, `b` = the retired-instruction delta.
    static let pmuSection: UInt16 = 0x0600

    /// Companion to `pmuSection` when extra event counters are programmed.
    /// `a`, `b` = the deltas of event counters 2 and 3.
    static let pmuEvents: UInt16 = 0x0601

    /// `info` = `TraceBootPhase`.
    static let bootPhase: UInt16 = 0x0700

    /// `a` = the new pid, `b` = the pid that asked for it.
    static let procSpawn: UInt16 = 0x0800

    /// The first 16 bytes of a process name, packed little-endian into
    /// `a` (bytes 0-7) and `b` (bytes 8-15). `info` = the name's length,
    /// `pid` overridden to carry the named process rather than the caller.
    static let procName: UInt16 = 0x0801

    /// `info` = the exit reason, `a` = the pid that died.
    static let procExit: UInt16 = 0x0802

    /// `info` = interaction point, `a` = correlation, `b` = point value.
    static let interactionMark: UInt16 = 0x0900
}
