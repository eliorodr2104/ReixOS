//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

@_silgen_name("_kernel_start")
public var _kernel_start: UInt8

@_silgen_name("_kernel_end")
public var _kernel_end: UInt8

@_cdecl("kernel_main")
public func kernelMain(dtbRawPtr: UInt64) {
    kprint("Hello on ReixOS!")
    
    Kernel.boot(dtbAddress: dtbRawPtr)
}
