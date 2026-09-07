//
//  TaskStartSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskStartSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskStart

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              let access   = TaskCapabilityAccess.task(
                rawHandle: frame.pointee.x0,
                right    : .taskStart,
                current  : current
              )
        else {
            frame.pointee.x0 = TaskResult.invalidCapability.rawValue
            frame.pointee.x1 = 0
            return
        }

        let job = Capability(
            target: .job(access.control),
            badge : access.capability.badge,
            rights: [.grant, .taskTerminate, .taskStatus]
        )

        let replacement = metadata.pointee.capsTable.install(at: access.handle, job)
        guard replacement.installed,
              replacement.displaced == access.capability
        else {
            frame.pointee.x0 = TaskResult.invalidState.rawValue
            frame.pointee.x1 = 0
            return
        }

        let started = context.processManager.pointee.startTask(
            access.control,
            context: context
        )

        if started.result != .ok {
            _ = metadata.pointee.capsTable.install(
                at: access.handle,
                access.capability
            )
        }

        frame.pointee.x0 = started.result.rawValue
        frame.pointee.x1 = started.pid
    }
}
