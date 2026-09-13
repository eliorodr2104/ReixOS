//
//  YieldSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `yield()` syscall provider.
///
/// Saves the running context, asks the scheduler for the next ready
/// task, and if one exists swaps the address space + trap frame so the
/// return-from-syscall lands on the new task.
import ReixABI

public struct YieldSyscall: SyscallProvider {

    public static let number: SyscallNumber = .yield

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        let current      = Arch.CPU.getCurrentProcess()
        let outgoingRoot = current?.pointee.addressSpace.rootTablePhysical

        if let trapFrame = context.scheduler.pointee.yield() {
            let next = Arch.CPU.getCurrentProcess()

            // A one-process ready queue rotates back to the frame already on
            // the exception stack. Scheduler accounting still happened, but
            // no architectural context or address space changed.
            if next == current {
                return
            }

            if let current, let savedContext = current.pointee.context {
                Arch.TrapFrame.copy(from: frame, to: savedContext)
            }

            if let next {
                let incomingRoot = next.pointee.addressSpace.rootTablePhysical

                if incomingRoot != outgoingRoot {
                    Arch.MMU.switchUserAddressSpace(
                        incomingRoot,
                        asid: next.pointee.addressSpace.asid
                    )
                }
            }
            Arch.TrapFrame.copy(from: trapFrame, to: frame)

        } else {
            if let current, let savedContext = current.pointee.context {
                Arch.TrapFrame.copy(from: frame, to: savedContext)
            }
            Arch.CPU.setCurrentProcess(0)
            Arch.CPU.idleLoop()
        }
    }
}
