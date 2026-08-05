//
//  TraceCategory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.
//

/// Which class of event a record belongs to, and therefore whether it is
/// compiled at all.
///
/// One conforming type per class. Static requirements only, and read through a
/// generic parameter, for the reason `PreemptionRegion` gives at length: in
/// Embedded Swift every generic call is specialized, so `isEnabled` and `bit`
/// are `static let`s of one concrete type inside each specialization of `emit`,
/// the `guard` in front of the body is a constant, and a class switched off
/// leaves no counter read, no ring write and no code at the emit site.
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
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 0
}


/// Context switches and the idle transitions around them.
enum TraceSched: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 1
}


/// Rendezvous blocks, wakes and message transfers.
enum TraceIPC: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 2
}


/// One record per owning `Preemption.run`, carrying the latency it cost.
enum TracePreemption: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 3
}


/// Subsystem bring-up milestones, from the first allocator to the first `eret`
/// into EL0.
enum TraceBoot: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 4
}


/// Process creation and death.
enum TraceProc: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 5
}


/// Timer-tick PC samples. Off in the default mask: at 100 Hz the samples
/// would crowd everything else out of the ring unless somebody asked.
enum TraceSampling: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 6
}


/// PMU-bracketed kernel sections. Off in the default mask for the same
/// reason as sampling: per-transfer counter reads are opt-in, not ambient.
enum TracePMU: TraceCategory {
    static let isEnabled: Bool   = true
    static let bit      : UInt32 = 1 << 7
}
