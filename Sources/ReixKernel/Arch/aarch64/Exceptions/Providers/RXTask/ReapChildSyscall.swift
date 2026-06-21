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
import ReixABI

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
        
        if let child = current.pointee.family.removeChild(id: childPid) {
            switch child.pointee.status {
                    
                // Case 1 — the child is already a zombie: reap it and return its code.
                case .terminated:
                    if child.pointee.family.parent?.pointee.pid == current.pointee.pid {
                        
                        if case .exited(let code)? = child.pointee.metadata?.pointee.exitReason {
                            frame.pointee.x0 = UInt64(code)
                            
                        } else { frame.pointee.x0 = 0 }
                        
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
                case .ready, .waiting:
                    current.pointee.metadata.pointee.waitingChildPid = childPid

                    // TODO: Add Error handler
                    try? context.scheduler.pointee.block(current.pointee.pid)

                    YieldSyscall.handle(frame: frame, context: context)
                    return
                
                default: break
            }
        }
                

        // Case 3 — no such child anywhere: nothing to reap.
        frame.pointee.x0 = 0
    }
}
