//
//  PMURegisterAccess.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
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
protocol PMURegisterAccess {
    static func readDebugFeatures() -> UInt64
    static func configure()
    static func readPMCR() -> UInt64
}
