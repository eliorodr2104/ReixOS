//
//  BridgeLogger.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//


// MARK: - C Bridge (sprintf fixed params)

@_extern(c, "format1")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64) -> UnsafePointer<Int8>

@_extern(c, "format2")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64, _ b: UInt64) -> UnsafePointer<Int8>

@_extern(c, "format3")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> UnsafePointer<Int8>

@_extern(c, "format4")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> UnsafePointer<Int8>
