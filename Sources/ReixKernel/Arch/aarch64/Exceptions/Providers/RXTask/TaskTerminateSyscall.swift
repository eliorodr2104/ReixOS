//
//  TaskTerminateSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskTerminateSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskTerminate

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let access = TaskCapabilityAccess.job(
                rawHandle: frame.pointee.x0,
                right    : .taskTerminate,
                current  : current
              )
        else {
            frame.pointee.x0 = TaskResult.invalidCapability.rawValue
            return
        }

        frame.pointee.x0 = context.processManager.pointee.terminateTask(
            access.control,
            frame  : frame,
            context: context
        ).rawValue
    }
}
