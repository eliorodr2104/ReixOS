//
//  EVTHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public enum Exception: UInt64 {
    case brk = 0x32
    case udf = 0x00
    
    public var message: StaticString {
        switch self {
            case .brk:
                "BRK Instruction"
                
            case .udf:
                "UDF Instruction"
        }
    }
}

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
            let internalReason = CPUArm64.internalKernelPanicMessage
            CPUArm64.panic(internalReason, exc: .brk, fp: frame)
            
        case 0x00:
            CPUArm64.panic(exc: .udf, fp: frame)
            
        default:
            CPUArm64.panic("EXC Unknown, Exception Class: ", fp: frame)
            // kprint(String(exceptionClass, radix: 16))
    }
    
    while true {  }
}
