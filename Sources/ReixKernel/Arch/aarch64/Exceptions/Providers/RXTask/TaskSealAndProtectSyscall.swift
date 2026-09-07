//
//  TaskSealAndProtectSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskSealAndProtectSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskSealAndProtect

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
              frame.pointee.x2 <= UInt64(UInt32.max),
              frame.pointee.x3 <= UInt64(UInt32.max)
        else {
            frame.pointee.x0 = TaskResult.invalidCapability.rawValue
            return
        }

        frame.pointee.x0 = context.processManager.pointee.sealTaskRegion(
            access.control,
            at         : frame.pointee.x1,
            pages      : UInt32(frame.pointee.x2),
            permissions: TaskMemoryPermissions(
                rawValue: UInt32(frame.pointee.x3)
            )
        ).rawValue
    }
}
