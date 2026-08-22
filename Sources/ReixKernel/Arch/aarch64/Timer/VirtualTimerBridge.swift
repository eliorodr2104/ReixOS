//
//  VirtualTimerBridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

@_silgen_name("enable_core_timer")
public func enable_core_timer()

@_silgen_name("rearm_core_timer")
public func rearm_core_timer()

@_silgen_name("read_virtual_counter")
public func read_virtual_counter() -> UInt64

@_silgen_name("read_virtual_counter_unordered")
public func read_virtual_counter_unordered() -> UInt64

@_silgen_name("read_counter_frequency")
public func read_counter_frequency() -> UInt64
