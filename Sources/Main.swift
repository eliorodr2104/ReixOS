//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

@_cdecl("kernel_main")
public func kernelMain(dtbRawAddress: UInt64) {    
    Kernel.boot(dtbRawAddress: dtbRawAddress)
}
