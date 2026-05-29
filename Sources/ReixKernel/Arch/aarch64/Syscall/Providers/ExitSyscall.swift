//
//  ExitSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `exit(code)` syscall provider.
///
/// Releases the running process address space and resources, records
/// the exit code on the cold metadata, optionally wakes a parent that
/// was waiting on it, then yields to the next ready task. When the
/// scheduler has nothing else to run the CPU parks in WFI.
public struct ExitSyscall: SyscallProvider {

    public static let number: SyscallNumber = .exit

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let currentAddr = Arch.CPU.getCurrentProcess()

        if let oldProcess = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {

            oldProcess.pointee.context?.pointee = frame.pointee
            oldProcess.pointee.status           = .terminated

            let exitingCode = UInt32(frame.pointee.x0)

            do {
                Arch.CPU.setCurrentProcess(0)
                try context.processManager.pointee.releaseAddressSpace(oldProcess)

            } catch { Arch.CPU.panic("Failed to destroy exiting process") }

            if let metadata = oldProcess.pointee.metadata {
                metadata.pointee.exitCode = exitingCode
            }
            context.scheduler.pointee.removeTask(oldProcess)


            if let parentPtr   = oldProcess.pointee.parent,
               let parentMeta  = parentPtr.pointee.metadata,
               parentMeta.pointee.waitingChildPid == oldProcess.pointee.pid,
               let parentFrame = parentPtr.pointee.context
            {
                parentFrame.pointee.x0 = frame.pointee.x0

                context.processManager.pointee.releaseProcess(oldProcess)

                try? context.scheduler.pointee.wakeUp(parentPtr.pointee.pid)
            }
        }

        if let trapFrame = context.scheduler.pointee.yield() {
            let nextAddr = Arch.CPU.getCurrentProcess()
            if let next = UnsafeMutablePointer<Process>(bitPattern: UInt(nextAddr)) {
                Arch.MMU.switchUserAddressSpace(next.pointee.addressSpace.rootTablePhysical.address)
            }
            frame.pointee = trapFrame.pointee

        } else {
            Arch.CPU.setCurrentProcess(0)
            while true { Arch.CPU.waitForInterrupt() }
        }
    }
}
