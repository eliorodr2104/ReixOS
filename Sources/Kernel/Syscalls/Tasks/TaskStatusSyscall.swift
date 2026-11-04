//
//  TaskStatusSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskStatusSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskStatus

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let control = TaskCapabilityAccess.status(
                rawHandle: frame.pointee.x0,
                current  : current
              )
        else {
            frame.pointee.x0 = TaskState.invalid.rawValue
            frame.pointee.x1 = 0
            return
        }

        let status = context.processManager.pointee.taskStatus(control)
        frame.pointee.x0 = status.state.rawValue
        frame.pointee.x1 = status.exitCode
    }
}
