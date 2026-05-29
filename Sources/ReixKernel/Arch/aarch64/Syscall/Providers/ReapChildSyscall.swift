//
//  ReapChildSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `reapChild(pid)` syscall provider.
///
/// If the requested child is already terminated, returns its exit code
/// and frees the zombie. Otherwise the parent is parked in the waiting
/// queue with `waitingChildPid` set and a yield is performed so the
/// scheduler can pick someone else.
public struct ReapChildSyscall: SyscallProvider {

    public static let number: SyscallNumber = .reapChild

    // TODO: - Create a ExitCode standard, zero val is a temp not found
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let childPid   = frame.pointee.x0
        let currentPtr = Arch.CPU.getCurrentProcess()

        // TODO: - Add throws for all case
        guard let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentPtr)) else {
            frame.pointee.x0 = 0
            return
        }

        guard let child = context.scheduler.pointee.search(to: childPid) else {
            frame.pointee.x0 = 0
            return
        }

        guard child.pointee.pid == current.pointee.pid else {
            frame.pointee.x0 = 0
            return
        }

        if child.pointee.status == .terminated {
            let childExit = child.pointee.metadata?.pointee.exitCode ?? 0
            frame.pointee.x0 = UInt64(childExit)

            context.processManager.pointee.releaseProcess(child)
            return
        }

        current.pointee.metadata.pointee.waitingChildPid = childPid

        // TODO: Add Error handler
        try? context.scheduler.pointee.block(current.pointee.pid)

        YieldSyscall.handle(frame: frame, context: context)
    }
}
