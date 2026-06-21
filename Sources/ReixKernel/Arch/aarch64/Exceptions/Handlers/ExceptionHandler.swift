//
//  EVTHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

/// The primary bridge between the Assembly exception vectors and the Swift kernel logic.
///
/// This function is called directly from the Low-Level Exception Vector Table (EVT).
/// It transitions the system from the raw architectural state to the kernel's
/// high-level exception handling logic.
///
/// - Parameters:
///   - rawFramePointer: A pointer to the stack location where the CPU state (GPRs) was saved.
///   - type: The numeric representation of the `ExceptionType` (e.g., Sync, IRQ).
///
/// - Important: This function uses `@_cdecl` to maintain a stable C-compatible
///   calling convention, as it is invoked from Assembly.
import ReixABI

@_cdecl("swift_exception_handler")
public func exceptionVirtualTableHandler(
    rawFramePointer: UnsafeMutableRawPointer,
    type           : UInt64
) {
    
    // Get exception type, if is not implemented, panic!
    guard let exceptionType = ExceptionType(rawValue: type) else {
        Arch.CPU.panic("Invalid Exception Type received from Assembly")
    }
    
    // Get TrapFrame
    let framePointer  = rawFramePointer.bindMemory(
        to      : Arch.TrapFrame.self,
        capacity: 1
    )
    
    handleExceptionType(exceptionType, framePointer: framePointer)
}

/// Dispatches exceptions based on their fundamental type.
///
/// This function handles:
/// 1. **IRQs**: Manages the Generic Interrupt Controller (GIC) and triggers the Scheduler.
/// 2. **Synchronous**: Decodes the Exception Class (EC) to handle Syscalls, Aborts, or Panics.
///
/// - Parameters:
///   - type: The fundamental exception category.
///   - framePointer: A typed pointer to the `TrapFrame` for state inspection or modification.
@inline(__always)
fileprivate
func handleExceptionType(
    _ type      : ExceptionType,
    framePointer: UnsafeMutablePointer<Arch.TrapFrame>
) {
    switch type {
        case .irq:
            let interruptID = Kernel.gic.pointee.acknowledgeInterrupt()
            InterruptDispatcher.dispatch(
                id   : interruptID,
                frame: framePointer
            )


        case .synchronous:
            let frame = framePointer.pointee
            let exceptionClass = (frame.esr >> 26) & 0b111111
            
            switch exceptionClass {
                case 0x15: // SVC Syscall
                    guard let type = SyscallNumber(rawValue: frame.x8) else {
                        return
                    }

                    Kernel.syscallHandler.pointee.handle(
                        type : type,
                        frame: framePointer
                    )

                case 0x24, 0x20: // User Space Abort (Data | Instruction)
                    userAbortHandle(frame: framePointer, faultAddress: frame.far)
                    
                case 0x25, 0x21: // Kernel Space Abort
                    Arch.CPU.panic("Kernel Space Abort", fp: frame)
                    
                case 0x3C: // BRK
                    Arch.CPU.panic("Breakpoint", exc: .breakpoint, fp: frame)
                    
                case 0x00: // UDF
                    Arch.CPU.panic(exc: .unknown, fp: frame)
                    
                default:
                    Arch.CPU.panic("EXC Unknown, Exception Class: ", fp: frame)
            }
    }
}

/// Handles memory access violations (Data/Instruction Aborts) originating from User Space (EL0).
///
/// It decodes the Data Fault Status Code (DFSC) from the ISS (Instruction Specific Syndrome)
/// to determine if the fault was a Translation Fault (Page Fault) or a Permission Fault (COW).
///
/// - Parameters:
///   - frame: The execution context of the user process.
///   - faultAddress: The virtual address that triggered the fault (from FAR_EL1).
fileprivate
func userAbortHandle(
    frame       : UnsafeMutablePointer<Arch.TrapFrame>,
    faultAddress: UInt64
) {
    let iss  = frame.pointee.esr & 0x1FFFFFF
    let dfsc = iss & 0x3F

    let cause: FaultCause
    switch dfsc {
        case 0x04...0x07: cause = .translation
        case 0x0C...0x0F: cause = .permission
        case 0x21       : cause = .alignment
        case 0x08...0x0B: cause = .access
        default:
            Arch.CPU.panic("Unhandled DFSC")
    }

    guard let process = Arch.CPU.getCurrentProcess() else {
        Arch.CPU.panic("User abort raised without a current process")
    }

    if process.pointee.addressSpace.handlePageFault(
        at   : faultAddress,
        cause: cause
    ) { return }

    kprintf(
        "[SEGFAULT] pid=%d far=0x%x elr=0x%x\n",
        process.pointee.pid,
        faultAddress,
        frame.pointee.elr
    )
    Kernel.syscallHandler.pointee.handle(type: .exit, frame: frame)
}
