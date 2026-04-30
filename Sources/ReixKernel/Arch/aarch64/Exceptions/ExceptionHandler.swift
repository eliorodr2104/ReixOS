//
//  EVTHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

@_cdecl("swift_exception_handler")
public func exceptionVirtualTableHandler(
    rawFramePointer: UnsafeMutableRawPointer,
    type           : UInt64
) {
    guard let exceptionType = ExceptionType(rawValue: type) else {
        Arch.CPU.panic("Invalid Exception Type received from Assembly")
    }
    let framePointer  = rawFramePointer.bindMemory(
        to      : Arch.TrapFrame.self,
        capacity: 1
    )
    
    switch exceptionType {
        case .irq:
            let interruptID = GIC.acknowledgeInterrupt()
            if interruptID == 27 {
                guard let isChangedProcess = Kernel.scheduler?.onTick() else { return }
                                
                if let current = Kernel.scheduler?.currentProcess {
                    current.pointee.context?.pointee = framePointer.pointee
                }
                
                AArch64VirtualTimer.arm()
                GIC.endOfInterrupt(id: interruptID)
                
                if isChangedProcess {
                    if let nextProcess = Kernel.scheduler?.selectNextTask() {
                        kprint("PID:")
                        kprint(nextProcess.pointee.pid)
                        kprint()
                        
                        framePointer.pointee = nextProcess.pointee.context!.pointee
                    }
                }
            }
            
            
        case .sync:
            let frame = framePointer.pointee
            let exceptionClass = (frame.esr >> 26) & 0b111111
            
            switch exceptionClass {
                case 0x3C:
                    let internalReason = Kernel.internalPanicMessage
                    Arch.CPU.panic(internalReason, exc: .brk, fp: frame)
                    
                case 0x00:
                    Arch.CPU.panic(exc: .udf, fp: frame)
                    
                default:
                    Arch.CPU.panic("EXC Unknown, Exception Class: ", fp: frame)
            }
    }
}
