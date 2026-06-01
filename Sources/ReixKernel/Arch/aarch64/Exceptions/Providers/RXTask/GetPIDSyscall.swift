//
//  GetPIDSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `getpid()` syscall provider. Writes the running process PID into
/// `x0`. Returns `0` when no current process is set, which only
/// happens during the kernel idle state.
public struct GetPIDSyscall: SyscallProvider {

    public static let number: SyscallNumber = .getPid

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        if let current = Arch.CPU.getCurrentProcess() {
            frame.pointee.x0 = UInt64(current.pointee.pid)

        } else { frame.pointee.x0 = 0 }
    }
}
