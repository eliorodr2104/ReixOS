//
//  EVTHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

@_cdecl("swift_exception_handler")
public func exceptionVirtualTableHandler(
    rawFramePointer: UnsafeMutableRawPointer
) {
    let framePointer = rawFramePointer.bindMemory(
        to      : TrapFrame.self,
        capacity: 1
    )
    
    let frame = framePointer.pointee
    let exceptionClass = (frame.esr >> 26) & 0b111111
    
    kprint("\n--- EXCEPTION ---")
    if exceptionClass == 0x3C {
        kprint("EXC: BRK (Probabile fatalError)")
        
    } else if exceptionClass == 0x00 {
        kprint("EXC: Undefined Instruction (UDF)")
        
    } else {
        kprintf("EXC Unknown, Exception Class: ")
        kprint(String(exceptionClass, radix: 16))
    }
    
    while true {  }
}
