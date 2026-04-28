//
//  EVTHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

enum ExceptionType: UInt64 {
    case irq  = 0
    case sync = 1
}

@_cdecl("swift_exception_handler")
public func exceptionVirtualTableHandler(
    rawFramePointer: UnsafeMutableRawPointer,
    type           : UInt64
) {
    guard let exceptionType = ExceptionType(rawValue: type) else {
        KernelCPU.panic("Invalid Exception Type received from Assembly")
    }
    let framePointer  = rawFramePointer.bindMemory(
        to      : TrapFrame.self,
        capacity: 1
    )
    
    switch exceptionType {
        case .irq:
            let interruptID = GIC.acknowledgeInterrupt()
            
            if interruptID == 30 {
                kprint("IRQ TIMER RECIVE")
                enable_core_timer()
                
            } else {
                kprintf("IRQ NOT FOUND: %d", UInt64(interruptID))
            }
            
            GIC.endOfInterrupt(id: interruptID)
            
        case .sync:
            let frame = framePointer.pointee
            let exceptionClass = (frame.esr >> 26) & 0b111111
            
            switch exceptionClass {
                case 0x3C:
                    let internalReason = Kernel.internalPanicMessage
                    KernelCPU.panic(internalReason, exc: .brk, fp: frame)
                    
                case 0x00:
                    KernelCPU.panic(exc: .udf, fp: frame)
                    
                default:
                    KernelCPU.panic("EXC Unknown, Exception Class: ", fp: frame)
            }
    }
}
