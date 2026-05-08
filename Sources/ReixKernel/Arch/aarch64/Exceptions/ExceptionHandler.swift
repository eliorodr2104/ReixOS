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
                
                let processAddress = Arch.CPU.getCurrentProcess()
                if processAddress != 0 {
                    let current = UnsafeMutablePointer<Process>(bitPattern: UInt(processAddress))
                    
                    if let c = current {
                        c.pointee.context?.pointee = framePointer.pointee
                    }
                }
                
                AArch64VirtualTimer.arm()
                GIC.endOfInterrupt(id: interruptID)
                
                if Kernel.scheduler.onTick() {
                    if let nextProcess = Kernel.scheduler.selectNextTask() {
                        
                        Arch.MMU.switchUserAddressSpace(
                            nextProcess.pointee.addressSpace.rootTablePhysical.address
                        )
                        framePointer.pointee = nextProcess.pointee.context!.pointee
                    }
                }
            }
            
            
        case .sync:
            let frame = framePointer.pointee
            let exceptionClass = (frame.esr >> 26) & 0b111111
            
            switch exceptionClass {
                case 0x15:
                    kprint("System call")
                    let syscallID = frame.x8

                    switch syscallID {
                        case SyscallNumber.exit.rawValue:
                            SyscallHandler.handleExit(frame: framePointer)
                        case SyscallNumber.yield.rawValue:
                            SyscallHandler.handleYield(frame: framePointer)
                        case SyscallNumber.debugPrint.rawValue:
                            SyscallHandler.handleDebugPrint(frame: framePointer)
                        default:
                            kprint("Unknown syscall")
                            kprint(syscallID)
                    }
                    
                    
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
