//
//  PMU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

/// The cycle counter, `PMCCNTR_EL0`.
///
/// Readable from EL0 because the kernel's `pmu_init` leaves `PMUSERENR_EL0.CR`
/// set, so a measured section costs two instructions and no syscall. Generated
/// by the reix plugin AsmDSL, and assembly rather than Swift for the reason
/// `readVirtualCounter` is: the value has to stay opaque to LLVM.
@_silgen_name("reix_pmu_cycles")
public func reixPMUCycles() -> UInt64

/// Event counter 0, retired instructions as the kernel programmed it.
///
/// Thirty-two bits, zero-extended by the read: it wraps roughly every four
/// billion instructions, which `PMUSection.end()` absorbs and a running total
/// would not.
@_silgen_name("reix_pmu_event0")
public func reixPMUEvent0() -> UInt64


/// One open measurement: the counters as they stood when the section began.
///
/// A value, not a handle, so nesting two sections is just two locals and the
/// whole thing stays allocation-free.
/// Nothing here enters the kernel, which is the point:
/// a section measured through a syscall would
/// mostly be measuring the syscall.
public struct PMUSection {

    public let startCycles      : UInt64
    public let startInstructions: UInt64


    /// Stamps both counters, cycles first.
    ///
    /// `end()` reads them in the same order on purpose: whatever the first read
    /// costs the second one is then present at both ends of the section and
    /// cancels out of the difference.
    @inline(__always)
    public static func begin() -> PMUSection {
        PMUSection(
            startCycles      : reixPMUCycles(),
            startInstructions: reixPMUEvent0()
        )
    }


    /// Closes the section and returns what it cost.
    ///
    /// The instruction counter is 32 bits wide, zero-extended by the read; a
    /// long section may well cross its wrap, and only a subtraction done in
    /// 32-bit arithmetic absorbs one, which is what this does before widening
    /// the result back to `UInt64`.
    @inline(__always)
    public func end() -> PMUDelta {
        let endCycles       = reixPMUCycles()
        let endInstructions = reixPMUEvent0()

        let instructionDelta = UInt32(truncatingIfNeeded: endInstructions)
            &- UInt32(truncatingIfNeeded: startInstructions)

        return PMUDelta(
            cycles      : endCycles &- startCycles,
            instructions: UInt64(instructionDelta)
        )
    }
}


/// What one `PMUSection` cost, in cycles and retired instructions.
@frozen
public struct PMUDelta {
    public let cycles      : UInt64
    public let instructions: UInt64
}
