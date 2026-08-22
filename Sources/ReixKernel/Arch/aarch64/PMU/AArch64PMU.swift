//
//  AArch64PMU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

public struct AArch64PMU: Loggable {
    
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
    
    public static let nameLog : StaticString = "[PMU ]"
    public static let logLevel: LogLevel     = .info


    /// Enables a supported block and programs counter 0, then says so.
    ///
    /// Called once from `Kernel.boot`, after the timer, because the boot line it
    /// prints belongs at that point in the log and for no deeper reason: the PMU
    /// depends on nothing the kernel builds.
    public static func initialize() {
        if initialize(using: HardwarePMURegisters.self) {
            Self.boot("\(eventCounters) event counters, cycle counter on.")
        }
    }

    static func initialize<Registers: PMURegisterAccess>(using: Registers.Type) -> Bool {
        initialized = false
        eventCounters = 0

        let version = (Registers.readDebugFeatures() >> 8) & 0xF
        switch version {
            case 1, 4, 5, 6, 7, 8, 9: break
            default: return false
        }

        Registers.configure()
        eventCounters = (Registers.readPMCR() >> 11) & 0x1F
        initialized = true
        return true
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
