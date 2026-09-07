//
//  TaskSetContextSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskSetContextSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskSetContext

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let access = TaskCapabilityAccess.task(
                rawHandle: frame.pointee.x0,
                right    : .taskConfigure,
                current  : current
              )
        else {
            frame.pointee.x0 = TaskResult.invalidCapability.rawValue
            return
        }

        frame.pointee.x0 = context.processManager.pointee.setTaskContext(
            access.control,
            entry       : frame.pointee.x1,
            stack       : frame.pointee.x2,
            programBreak: frame.pointee.x3
        ).rawValue
    }
}
