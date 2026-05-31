//
//  GetParentPIDSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

/// `getParentPid()` syscall provider. Writes the parent process PID into
/// `x0`. Returns `0` when no current process is set, which only
/// happens during the kernel idle state.
public struct GetParentPIDSyscall: SyscallProvider {

    public static let number: SyscallNumber = .getPid

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context
        let currentRawProcess = Arch.CPU.getCurrentProcess()

        if let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentRawProcess)),
           let parent  = current.pointee.family.parent {
            frame.pointee.x0 = UInt64(parent.pointee.pid)

        } else { frame.pointee.x0 = 0 }
    }
}
