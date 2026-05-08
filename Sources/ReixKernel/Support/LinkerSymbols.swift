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


@_silgen_name("_bss_start")
public var _bss_start: UInt8

@_silgen_name("_bss_end")
public var _bss_end: UInt8


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

public let KernelVirtualOffset: UInt64 = 0xFFFF800000000000

public func getOfaddressWithSymbol(of symbol: inout UInt8) -> VirtualAddress {
    withUnsafePointer(to: &symbol) {
        UInt64(UInt(bitPattern: $0))
    }
}

@inline(__always)
public func kernelVirtualToPhysical(_ addr: VirtualAddress) -> PhysicalAddress {
    addr >= KernelVirtualOffset ? (addr - KernelVirtualOffset) : addr
}

@inline(__always)
public func kernelPhysicalToVirtual(_ addr: PhysicalAddress) -> VirtualAddress {
    addr + KernelVirtualOffset
}

@inline(__always)
public func getKernelPhysicalAddressWithSymbol(of symbol: inout UInt8) -> PhysicalAddress {
    kernelVirtualToPhysical(getOfaddressWithSymbol(of: &symbol))
}
