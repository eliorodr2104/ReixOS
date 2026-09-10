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
              metadata.pointee.capsTable.findFirst(for: .spawn) != nil
        else {
            fail(frame)
            return
        }

        var requestedName: InlineArray<16, UInt8>? = nil
        var nameLength = 0

        if frame.pointee.x0 != 0 || frame.pointee.x1 != 0 {
            guard frame.pointee.x0 != 0,
                  frame.pointee.x1 > 0,
                  frame.pointee.x1 <= UInt64(TaskCreation.maximumNameBytes)
            else {
                fail(frame)
                return
            }

            nameLength = Int(frame.pointee.x1)
            var name = InlineArray<16, UInt8>(repeating: 0)
            let copied = withUnsafeMutableBytes(of: &name) { bytes in
                UserMemory.copyFromUser(
                    kernelDest: bytes.baseAddress!,
                    userSrc   : frame.pointee.x0,
                    count     : nameLength
                )
            }
            guard copied else {
                fail(frame)
                return
            }

            for index in 0..<nameLength {
                guard name[index] >= 0x20, name[index] <= 0x7E else {
                    fail(frame)
                    return
                }
            }
            requestedName = name
        }

        guard metadata.pointee.capsTable.hasFreeSlots(2),
              let created = context.processManager.pointee.createSuspendedTask(
                ownedBy   : current,
                name      : requestedName,
                nameLength: nameLength
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
