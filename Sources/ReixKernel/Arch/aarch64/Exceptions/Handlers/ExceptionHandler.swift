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
                case 0x15: // SVC Syscall
                    guard let type = SyscallNumber(rawValue: frame.x8) else {
                        return
                    }
                    
                    SyscallHandler.handle(
                        type : type,
                        frame: framePointer
                    )
                    
                case 0x24, 0x20: // User Space Abort (Data | Instruction)
                    userAbortHandle(frame: framePointer, faultAddress: frame.far)
                    
                case 0x25, 0x21: // Kernel Space Abort
                    Arch.CPU.panic("Kernel Space Abort", fp: frame)
                    
                case 0x3C: // BRK
                    Arch.CPU.panic("Breakpoint", exc: .brk, fp: frame)
                    
                case 0x00: // UDF
                    Arch.CPU.panic(exc: .udf, fp: frame)
                    
                default:
                    Arch.CPU.panic("EXC Unknown, Exception Class: ", fp: frame)
            }
    }
}

fileprivate
func userAbortHandle(
    frame       : UnsafeMutablePointer<Arch.TrapFrame>,
    faultAddress: UInt64
) {
    let iss  = frame.pointee.esr & 0x1FFFFFF
    let dfsc = iss & 0x3F
    
    switch dfsc {
        case 0x04...0x07: // TRANSLATION FAULT
//            if Kernel.vmm.handlePageFault(addr: faultAddress) {
//                return // Torna all'utente, l'istruzione verrà ri-eseguita con successo
//                
//            } else {
//                SyscallHandler.handle(type: .exit, frame: frame)
//            }
            SyscallHandler.handle(type: .exit, frame: frame)
            
        case 0x0C...0x0F: // PERMISSION FAULT
            
//            if Kernel.vmm.isCopyOnWrite(addr: faultAddress) {
//                Kernel.vmm.handleCOW(addr: faultAddress)
//                return
//                
//            } else { SyscallHandler.handle(type: .exit, frame: frame) }
            
            SyscallHandler.handle(type: .exit, frame: frame)
            
        case 0x21:
            SyscallHandler.handle(type: .exit, frame: frame)
            
        default:
            Arch.CPU.panic("Unhandled DFSC")
    }
}
