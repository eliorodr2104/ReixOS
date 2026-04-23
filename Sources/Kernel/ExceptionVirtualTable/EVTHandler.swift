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
        
    switch exceptionClass {
        case 0x3C:
            let internalReason = Kernel.internalPanicMessage
            CPUArm64.panic(internalReason, exc: .brk, fp: frame)
            
        case 0x00:
            CPUArm64.panic(exc: .udf, fp: frame)
            
        default:
            CPUArm64.panic("EXC Unknown, Exception Class: ", fp: frame)
    }
}
