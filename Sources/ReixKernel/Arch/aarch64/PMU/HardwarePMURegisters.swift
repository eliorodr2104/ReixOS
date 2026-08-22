//
//  HardwarePMURegisters.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


internal enum HardwarePMURegisters: PMURegisterAccess {
    static func readDebugFeatures() -> UInt64 { pmu_read_id_aa64dfr0() }
    static func configure() { pmu_init() }
    static func readPMCR() -> UInt64 { pmu_read_pmcr() }
}
