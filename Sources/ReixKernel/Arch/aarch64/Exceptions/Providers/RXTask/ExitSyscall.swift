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
/// scheduler has nothing else to run the CPU unmasks IRQs and parks in
/// WFI so the next timer tick or device interrupt can re-enter the
/// scheduler once a task becomes runnable again.
import ReixABI

public struct ExitSyscall: SyscallProvider {

    public static let number: SyscallNumber = .exit

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        if let oldProcess = Arch.CPU.getCurrentProcess() {

            oldProcess.pointee.context?.pointee = frame.pointee
            oldProcess.pointee.status           = .terminated

            // Reclaim any IPC endpoints this process owned, otherwise its slots
            // in the fixed 64-entry endpoint table leak on every exit.
            context.ipc.pointee.releaseCapabilities(of: oldProcess)

            let exitingCode = UInt32(frame.pointee.x0)
            do {
                Arch.CPU.setCurrentProcess(0)
                try context.processManager.pointee.releaseAddressSpace(oldProcess)

            } catch { Arch.CPU.panic("Failed to destroy exiting process") }

            if let metadata = oldProcess.pointee.metadata {
                metadata.pointee.exitCode = exitingCode
            }

            // If have a parent and this is blocked waiting his children
            // wakeup him
            if let parentPtr   = oldProcess.pointee.family.parent,
               let parentMeta  = parentPtr.pointee.metadata,
               parentMeta.pointee.waitingChildPid == oldProcess.pointee.pid,
               let parentFrame = parentPtr.pointee.context
            {
                parentFrame.pointee.x0 = frame.pointee.x0
                context.processManager.pointee.releaseProcess(oldProcess)
                try? context.scheduler.pointee.wakeUp(parentPtr.pointee.pid)

            } else { context.scheduler.pointee.removeTask(oldProcess) }
        }

        // Switch address with current process enter to consuming CPU
        if let trapFrame = context.scheduler.pointee.yield() {

            if let next = Arch.CPU.getCurrentProcess() {
                Arch.MMU.switchUserAddressSpace(next.pointee.addressSpace.rootTablePhysical.address)
            }
            frame.pointee = trapFrame.pointee

        } else {
            Arch.CPU.setCurrentProcess(0)
            Arch.CPU.enableInterrupts()
            while true { Arch.CPU.waitForInterrupt() }
        }
    }
}
