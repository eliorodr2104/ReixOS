//
//  LinkerSymbols.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//
//  These variables are external references to symbols emitted by the linker
//  script (linker.ld). They mark the boundaries of the kernel image in
//  physical memory and are used by both the Physical Page Manager (to reserve
//  the kernel region) and the Virtual Memory Manager (to identity-map it
//  before enabling the MMU).
//
//  Usage: take the address of the variable to obtain the boundary address,
//  e.g. `withUnsafePointer(to: &_kernel_start) { UInt64(UInt(bitPattern: $0)) }`

@_silgen_name("_kernel_start")
var _kernel_start: UInt8   // first byte of the kernel image

@_silgen_name("_kernel_end")
var _kernel_end: UInt8     // first byte after kernel code/data/BSS

@_silgen_name("_evt_start")
var _evt_start: UInt8      // first byte of the exception vector table

@_silgen_name("_evt_end")
var _evt_end: UInt8        // first byte after the exception vector table
