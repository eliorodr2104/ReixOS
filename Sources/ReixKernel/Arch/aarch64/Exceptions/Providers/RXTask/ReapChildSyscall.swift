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

        // TODO: - Add throws for all case
        guard let current = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = 0
            return
        }

        // Case 1 — the child is already a zombie: reap it and return its code.
        if let child = context.scheduler.pointee.search(in: .terminated, to: childPid),
           child.pointee.family.parent?.pointee.pid == current.pointee.pid,
           case .terminated = child.pointee.status {

            let childExit = child.pointee.metadata?.pointee.exitCode ?? 0
            frame.pointee.x0 = UInt64(childExit)

            _ = context.scheduler.pointee.reapChild(child)
            context.processManager.pointee.releaseProcess(child)
            return
        }

        // Case 2 — the child is still alive (ready or waiting): park the caller
        // until it exits. `ExitSyscall` sees `waitingChildPid`, releases the
        // child and wakes us with its exit code in x0. This is the backpressure
        // a split()/reapChild() loop relies on: without it the parent forks
        // without ever yielding, so children pile up live in the ready queue
        // and exhaust physical memory long before they get to run.
        let stillReady   = context.scheduler.pointee.search(in: .ready,   to: childPid)
        let stillWaiting = context.scheduler.pointee.search(in: .waiting, to: childPid)

        if stillReady != nil || stillWaiting != nil {
            current.pointee.metadata.pointee.waitingChildPid = childPid

            // TODO: Add Error handler
            try? context.scheduler.pointee.block(current.pointee.pid)

            YieldSyscall.handle(frame: frame, context: context)
            return
        }

        // Case 3 — no such child anywhere: nothing to reap.
        frame.pointee.x0 = 0
    }
}
