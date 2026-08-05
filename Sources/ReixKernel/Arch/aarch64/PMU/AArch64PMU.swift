//
//  AArch64PMU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// The Performance Monitors Unit, v3: a cycle counter and one programmed event.
///
/// What the virtual timer cannot answer. `Arch.Timer.counter()` says how long a
/// section took in wall time, which on a TCG guest is mostly a statement about
/// the host; the cycle and retired-instruction counters say how much work the
/// section actually was, and that number is stable enough to compare two builds.
///
/// Only counter 0 is programmed, to `INST_RETIRED`. The rest are left alone and
/// reported by `probe()` so a later phase can claim them without this file
/// deciding in advance what they are for.
public struct AArch64PMU {

    /// Whether `initialize()` has run.
    ///
    /// Every read site guards on this rather than on the counters being
    /// non-zero: a counter legitimately reads zero, and a read before the block
    /// is enabled returns a number that looks exactly like a real one.
    public private(set) static var initialized = false

    /// Programmable event counters this implementation has, `PMCR_EL0.N`.
    ///
    /// The cycle counter is not one of them: it is a separate register with its
    /// own enable bit, always present, and never included in this count.
    public private(set) static var eventCounters: UInt64 = 0


    /// Enables the block and programs counter 0, then says so.
    ///
    /// Called once from `Kernel.boot`, after the timer, because the boot line it
    /// prints belongs at that point in the log and for no deeper reason: the PMU
    /// depends on nothing the kernel builds.
    public static func initialize() {
        pmu_init()

        eventCounters = (pmu_read_pmcr() >> 11) & 0x1F
        initialized   = true

        Self.boot("\(eventCounters) event counters, cycle counter on.")
    }


    /// How many event counters user space can expect, for
    /// `profileControl(.pmuProbe)`. Zero before `initialize()`, which is the
    /// honest answer: nothing is counting yet.
    public static func probe() -> UInt64 {
        eventCounters
    }


    /// The cycle counter, `PMCCNTR_EL0`.
    ///
    /// Ordered against the surrounding instruction stream, like
    /// `Arch.Timer.counter()` and for the same reason: a pair of reads has to
    /// really bracket the work between them.
    @_transparent
    public static func cycles() -> UInt64 {
        pmu_read_cycles()
    }


    /// Retired instructions, event counter 0 as `initialize()` programmed it.
    ///
    /// A 32-bit counter, zero-extended by the read. It wraps roughly every four
    /// billion instructions, which a section delta absorbs with `&-` and a
    /// long-running total does not.
    @_transparent
    public static func instructions() -> UInt64 {
        pmu_read_event0()
    }
}


extension AArch64PMU: Loggable {
    public static let nameLog : StaticString = "[PMU ]"
    public static let logLevel: LogLevel     = .info
}


/// Reachable as `Arch.PMU`, the way the timer is reachable as `Arch.Timer`.
///
/// An extension rather than a member of `AArch64` itself because
/// `KernelArchitecture` has no `PMU` requirement: a port with no performance
/// monitor is a port with no counters, not one that fails to build.
extension AArch64 {
    public typealias PMU = AArch64PMU
}
