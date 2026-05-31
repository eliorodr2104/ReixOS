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
public struct YieldSyscall: SyscallProvider {

    public static let number: SyscallNumber = .yield

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let currentAddr = Arch.CPU.getCurrentProcess()
        if let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {
            current.pointee.context?.pointee = frame.pointee
        }

        if let trapFrame = context.scheduler.pointee.yield() {
            let nextAddr = Arch.CPU.getCurrentProcess()

            if let next = UnsafeMutablePointer<Process>(bitPattern: UInt(nextAddr)) {
                Arch.MMU.switchUserAddressSpace(next.pointee.addressSpace.rootTablePhysical.address)
            }
            frame.pointee = trapFrame.pointee
        }
    }
}
