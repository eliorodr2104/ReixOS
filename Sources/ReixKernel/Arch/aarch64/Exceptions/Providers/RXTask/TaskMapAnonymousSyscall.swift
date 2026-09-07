//
//  TaskMapAnonymousSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskMapAnonymousSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskMapAnonymous

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let access = TaskCapabilityAccess.task(
                rawHandle: frame.pointee.x0,
                right    : .taskConfigure,
                current  : current
              ),
              frame.pointee.x2 <= UInt64(UInt32.max)
        else {
            frame.pointee.x0 = TaskResult.invalidCapability.rawValue
            return
        }

        frame.pointee.x0 = context.processManager.pointee.mapTaskAnonymous(
            access.control,
            at   : frame.pointee.x1,
            pages: UInt32(frame.pointee.x2)
        ).rawValue
    }
}
