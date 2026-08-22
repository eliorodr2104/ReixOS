//
//  PMUBridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

@_silgen_name("pmu_init")
public func pmu_init()

@_silgen_name("pmu_read_id_aa64dfr0")
public func pmu_read_id_aa64dfr0() -> UInt64

@_silgen_name("pmu_read_pmcr")
public func pmu_read_pmcr() -> UInt64

@_silgen_name("pmu_read_cycles")
public func pmu_read_cycles() -> UInt64

@_silgen_name("pmu_read_event0")
public func pmu_read_event0() -> UInt64
