//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

@_cdecl("kernel_main")
public func kernelMain(dtbRawPtr: UInt64) {
    kprint("Hello on ReixOS!")
    
    Kernel.boot(dtbAddress: dtbRawPtr)
}
