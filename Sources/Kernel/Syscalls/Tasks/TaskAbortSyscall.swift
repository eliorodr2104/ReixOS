//
//  TaskAbortSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskAbortSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskAbort

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let access = TaskCapabilityAccess.task(
                rawHandle: frame.pointee.x0,
                right    : .taskAbort,
                current  : current
              )
        else {
            frame.pointee.x0 = TaskResult.invalidCapability.rawValue
            return
        }

        frame.pointee.x0 = context.processManager.pointee.abortTask(
            access.control,
            context: context
        ).rawValue
    }
}
