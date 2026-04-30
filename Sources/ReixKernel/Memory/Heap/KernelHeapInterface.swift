//
//  KernelHeapInterface.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public protocol KernelHeapInterface {
        
    static func initialize(ppmPtr: UnsafeMutablePointer<KernelPPM>)
    
    static func kmalloc(_ byte: UInt) throws(PPMError) -> UnsafeMutableRawPointer?
    static func kfree(_ ptr: UnsafeMutableRawPointer) 
}
