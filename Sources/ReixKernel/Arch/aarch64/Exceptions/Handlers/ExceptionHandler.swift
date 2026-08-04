//
//  EVTHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

import ReixABI

/// The primary bridge between the Assembly exception vectors and the Swift kernel logic.
///
/// This function is called directly from the Low-Level Exception Vector Table (EVT).
/// It transitions the system from the raw architectural state to the kernel's
/// high-level exception handling logic.
///
/// - Parameters:
///   - rawFramePointer: A pointer to the stack location where the CPU state (GPRs) was saved.
///   - type: The numeric representation of the `ExceptionType` (Sync, IRQ).
///
/// - Important: This function uses `@_cdecl` to maintain a stable C-compatible
///   calling convention, as it is invoked from Assembly.
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

    let frameAddress = UInt(bitPattern: rawFramePointer)

    KernelStack.noteEntry(at: frameAddress, frame: framePointer)

    handleExceptionType(exceptionType, framePointer: framePointer)

    guard Kernel.scheduler.pointee.needsResched else { return }

    performPendingSwitch(frame: framePointer, at: frameAddress)
}


/// Where the outermost exception frame sits on the single kernel stack.
///
/// `jump_to_user_mode` and `kernel_idle_loop` both re-anchor SP at the
/// linker's `stack_top`, and every entry unwinds back to it, so an exception
/// with no kernel work beneath it always pushes its frame at one fixed
/// address. That address is learned from the first entry taken from EL0
/// instead of being read from `stack_top`, which Swift cannot name and whose
/// value would have to track changes to the stack layout in `linker.ld`.
///
/// A frame built on the exception stack can never become this anchor, so the
/// second stack `check_kernel_stack` switches to leaves the comparison intact:
/// the anchor is only ever taken from an entry arriving at EL0, and only
/// entries taken at EL1 are ever diverted off the kernel stack.
fileprivate struct KernelStack {

    static var outermostFrame: UInt = 0

    /// Anchors `outermostFrame` on the first exception arriving from EL0.
    ///
    /// EL0 is unreachable from inside kernel work, so such a frame is the
    /// outermost one by construction and its address is the anchor. Recorded
    /// once rather than on every entry, so the comparison stays a genuine
    /// test of where this frame is and not a moving target.
    @inline(__always)
    static func noteEntry(
        at    address: UInt,
        frame        : UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        guard outermostFrame == 0, frame.pointee.spsr & 0xF == 0 else {
            return
        }

        outermostFrame = address
    }
}


/// Installs the next ready task, the one place in the kernel that does.
///
/// This is the deferred half of preemption: the timer tick records that the
/// quantum is spent and this runs on the way out of the kernel, so a tick
/// taken at EL1 pauses the interrupted syscall instead of abandoning it.
///
/// Two conditions gate the swap, and both are about the frame rather than
/// about the tick. The frame must be the outermost one: below a nested frame
/// lies a half-finished kernel call whose Swift state `eret` cannot come back
/// to, and whose stack space would never be reclaimed, walking SP down by one
/// frame per preemption. And control must genuinely be leaving the kernel,
/// which a return to EL0 proves. The idle loop is the single EL1 context that
/// also qualifies: it holds no current process, keeps nothing worth resuming
/// and re-anchors SP itself, and a tick is the only thing that ever gets the
/// CPU back out of it.
fileprivate
func performPendingSwitch(
    frame      : UnsafeMutablePointer<Arch.TrapFrame>,
    at  address: UInt
) {
    guard address == KernelStack.outermostFrame else { return }

    let returningToEL0 = frame.pointee.spsr & 0xF == 0
    let current        = Arch.CPU.getCurrentProcess()

    guard returningToEL0 || current == nil else { return }

    var outgoingRoot: PhysicalAddress? = nil

    if let current {
        current.pointee.context?.pointee = frame.pointee
        outgoingRoot = current.pointee.addressSpace.rootTablePhysical
    }

    guard let nextProcess = Kernel.scheduler.pointee.selectNextTask() else {
        return
    }

    let incomingRoot = nextProcess.pointee.addressSpace.rootTablePhysical

    if incomingRoot != outgoingRoot {
        Arch.MMU.switchUserAddressSpace(
            incomingRoot,
            asid: nextProcess.pointee.addressSpace.asid
        )
    }

    guard let nextContext = nextProcess.pointee.context else {
        Arch.CPU.panic(
            report: PanicReport(
                reason: "Ready process has no saved context (broken invariant)",
                frame : frame.pointee,
                pid   : nextProcess.pointee.pid
            ),
            formattedBy: DefaultPanicFormatter.self,
            finishedBy : HaltPanicAction.self
        )
    }

    frame.pointee = nextContext.pointee
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
                        framePointer.pointee.x0 = UInt64.max
                        return
                    }

                    Kernel.syscallHandler.pointee.handle(
                        type : type,
                        frame: framePointer
                    )

                case 0x24, 0x20: // User Space Abort (Data | Instruction)
                    userAbortHandle(frame: framePointer, faultAddress: frame.far)
                    
                case 0x25, 0x21: // Kernel Space Abort (Data | Instruction)
                    if exceptionClass == 0x25, isStackGuardFault(at: frame.far) {
                        Arch.CPU.panic(
                            "Kernel stack overflow (fault inside the kernel stack guard page)",
                            fp: frame
                        )
                    }

                    Arch.CPU.panic("Kernel Space Abort", fp: frame)
                    
                case 0x3C: // BRK
                    Arch.CPU.panic("Breakpoint", exc: .breakpoint, fp: frame)
                    
                case 0x00: // UDF
                    if frame.spsr & 0xF == 0 {
                        Kernel.syscallHandler.pointee.killCurrent(frame: framePointer, reason: .illegalInstruction)
               
                    } else { Arch.CPU.panic(exc: .unknown, fp: frame) }
                    
                default:
                    Arch.CPU.panic("EXC Unknown, Exception Class: ", fp: frame)
            }
    }
}


/// Whether a kernel data abort landed in the kernel stack's guard page.
///
/// The reason line is the first thing anyone reads, and "Kernel Space Abort"
/// for an overflow sends the reader hunting a bad pointer instead of a deep
/// call chain. The guard page is unmapped and no other structure is addressed
/// through it, so a fault inside it is a stack overflow to a good approximation.
///
/// Folded into the low alias before comparing: the linker symbols are placed at
/// physical addresses, while `FAR_EL1` reports whichever alias the faulting
/// access used, and the kernel stack is reached through the high one from the
/// first entry into user mode onward.
@inline(__always)
fileprivate
func isStackGuardFault(at address: UInt64) -> Bool {
    let physical = address & ~VirtualMemoryManager.physicalOffset

    return physical >= getOfaddressWithSymbol(of: &__stack_guard_bottom)
        && physical <  getOfaddressWithSymbol(of: &__stack_guard_top)
}


/// Handles memory access violations (Data/Instruction Aborts) originating from User Space (EL0).
///
/// It decodes the Data Fault Status Code (DFSC) from the ISS (Instruction Specific Syndrome)
/// into a `FaultCause`: translation (page fault), permission (COW), access flag,
/// or alignment.
///
/// A DFSC the kernel cannot classify carries no `FaultCause`, so it skips the
/// page-fault servicing attempt and terminates the process directly: there is
/// nothing to service when the fault is not understood.
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
    
    let cause: FaultCause? = switch dfsc {
        case 0x04...0x07: .translation
        case 0x0C...0x0F: .permission
        case 0x21       : .alignment
        case 0x08...0x0B: .access
        default         : nil
    }

    guard let process = Arch.CPU.getCurrentProcess() else {
        Arch.CPU.panic("User abort raised without a current process")
    }

    if let cause, process.pointee.addressSpace.handlePageFault(
        at   : faultAddress,
        cause: cause
    ) { return }


    kprint("[SEGFAULT] pid=\(process.pointee.pid) far=0x\(hex: faultAddress) elr=0x\(hex: frame.pointee.elr) dfsc=0x\(hex: dfsc)")

    let guardLow = UserSpaceLayout.stackLimit - UInt64(UserSpaceLayout.guardPageCount) * UserSpaceLayout.pageSize
    
    let reason: ExitReason = if faultAddress >= guardLow &&
                                faultAddress < UserSpaceLayout.stackLimit { .stackOverflow } else { .memoryFault(cause ?? .translation) }

    Kernel.syscallHandler.pointee.killCurrent(
        frame : frame,
        reason: reason
    )
}
