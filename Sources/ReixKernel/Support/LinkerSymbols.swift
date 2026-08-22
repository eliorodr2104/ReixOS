//
//  LinkerSymbols.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

@_silgen_name("_text_start")
public var _text_start: UInt8

@_silgen_name("_text_end")
public var _text_end: UInt8


@_silgen_name("_rodata_start")
public var _rodata_start: UInt8

@_silgen_name("_rodata_end")
public var _rodata_end: UInt8


@_silgen_name("_data_start")
public var _data_start: UInt8

@_silgen_name("_data_end")
public var _data_end: UInt8


@_silgen_name("__bss_start")
public var __bss_start: UInt8

@_silgen_name("__bss_end")
public var __bss_end: UInt8


@_silgen_name("_kernel_start")
public var _kernel_start: UInt8

@_silgen_name("_kernel_end")
public var _kernel_end: UInt8


@_silgen_name("_evt_start")
public var _evt_start: UInt8

@_silgen_name("_evt_end")
public var _evt_end: UInt8


@_silgen_name("_kernel_total_end")
public var _kernel_total_end: UInt8


/// Bounds of the kernel stack's guard page, from `linker.ld`.
///
/// The page between `_kernel_end` and `__stack_bottom` that the linear map has
/// to skip. Never dereference either symbol: the whole point is that the page
/// they delimit has no translation.
@_silgen_name("__stack_guard_bottom")
public var __stack_guard_bottom: UInt8

@_silgen_name("__stack_guard_top")
public var __stack_guard_top: UInt8

@_silgen_name("__stack_bottom")
public var __stack_bottom: UInt8

@_silgen_name("stack_top")
public var stack_top: UInt8

@_silgen_name("__exception_stack_bottom")
public var __exception_stack_bottom: UInt8

@_silgen_name("__exception_stack_top")
public var __exception_stack_top: UInt8

public func getOfaddressWithSymbol(of symbol: inout UInt8) -> PhysicalAddress {
    return withUnsafePointer(to: &symbol) {
        UInt64(UInt(bitPattern: $0))
    }
}
