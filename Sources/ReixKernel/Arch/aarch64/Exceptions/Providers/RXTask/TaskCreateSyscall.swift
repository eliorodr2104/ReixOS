//
//  TaskCreateSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct TaskCreateSyscall: SyscallProvider {
    public static let number: SyscallNumber = .taskCreate

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              metadata.pointee.capsTable.findFirst(for: .spawn) != nil,
              metadata.pointee.capsTable.hasFreeSlots(2),
              let created = context.processManager.pointee.createSuspendedTask(
                ownedBy: current
              )
        else {
            fail(frame)
            return
        }

        guard case .success(let bootstrap) = context.ipc.pointee.spawnEndpoint(
            for: current,
            and: created.process
        ) else {
            _ = context.processManager.pointee.abortTask(
                created.control,
                context: context
            )
            fail(frame)
            return
        }

        let taskCapability = Capability(
            target: .task(created.control),
            badge : 0,
            rights: [.taskConfigure, .taskStart, .taskAbort, .taskStatus]
        )

        guard let taskHandle = metadata.pointee.capsTable.install(taskCapability) else {
            _ = context.ipc.pointee.releaseCapability(bootstrap, of: current)
            _ = context.processManager.pointee.abortTask(
                created.control,
                context: context
            )
            fail(frame)
            return
        }

        context.ipc.pointee.retain(taskCapability)

        created.process.pointee.family.parent = current
        current.pointee.family.pushChild(created.process)

        frame.pointee.x0 = UInt64(taskHandle)
        frame.pointee.x1 = UInt64(bootstrap)
    }

    private static func fail(_ frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        frame.pointee.x0 = UInt64(UInt32.max)
        frame.pointee.x1 = UInt64(UInt32.max)
    }
}
