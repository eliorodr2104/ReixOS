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

        var outgoingRoot: PhysicalAddress? = nil

        if let current = Arch.CPU.getCurrentProcess() {
            current.pointee.context?.pointee = frame.pointee
            outgoingRoot = current.pointee.addressSpace.rootTablePhysical
        }

        if let trapFrame = context.scheduler.pointee.yield() {

            if let next = Arch.CPU.getCurrentProcess() {
                let incomingRoot = next.pointee.addressSpace.rootTablePhysical

                if incomingRoot != outgoingRoot {
                    Arch.MMU.switchUserAddressSpace(
                        incomingRoot,
                        asid: next.pointee.addressSpace.asid
                    )
                }
            }
            frame.pointee = trapFrame.pointee

        } else {
            Arch.CPU.setCurrentProcess(0)
            Arch.CPU.idleLoop()
        }
    }
}
