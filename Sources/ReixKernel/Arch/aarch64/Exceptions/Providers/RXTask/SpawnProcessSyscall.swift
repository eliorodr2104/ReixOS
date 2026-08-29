//
//  SpawnProcessSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 29/05/2026.
//

import ReixABI

public struct SpawnProcessSyscall: SyscallProvider {

    public static let number: SyscallNumber = .spawnProcess

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        guard let currentProcess = Arch.CPU.getCurrentProcess(),
              let _ = currentProcess.pointee.metadata.pointee.capsTable.findFirst(for: .spawn) else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = UInt64(UInt32.max)
            return
        }

        guard frame.pointee.x0 != 0 else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = UInt64(UInt32.max)
            return // throw .nullPointer
        }

        guard frame.pointee.x1 <= 100 else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = UInt64(UInt32.max)
            return
        }

        let length = Int(frame.pointee.x1)

        // Init may hand Shell nine capabilities normally and ten when terminal
        // profiling is enabled, so this syscall must retain both complete lists.
        var grants      = InlineArray<10, CapGrant>(repeating: CapGrant())
        var grantsCount = 0

        guard frame.pointee.x3 <= 10 else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = UInt64(UInt32.max)
            return
        }

        if frame.pointee.x3 > 0 {
            let count = Int(frame.pointee.x3)

            let copied = withUnsafeMutableBytes(of: &grants) { raw in
                UserMemory.copyFromUser(
                    kernelDest: raw.baseAddress!,
                    userSrc   : frame.pointee.x2,
                    count     : count * MemoryLayout<CapGrant>.stride
                )
            }

            guard copied else {
                frame.pointee.x0 = UInt64.max
                frame.pointee.x1 = UInt64(UInt32.max)
                return
            }

            grantsCount = count
        }

        var childProcess: UnsafeMutablePointer<Process>?

        if length != 0 {
            withUnsafeTemporaryAllocation(
                byteCount: length + 1,
                alignment: MemoryLayout<CChar>.alignment
            ) { buffer in
                let base = buffer.baseAddress!

                guard UserMemory.copyFromUser(
                    kernelDest: base,
                    userSrc   : frame.pointee.x0,
                    count     : length
                ) else { frame.pointee.x0 = UInt64.max; return }

                base.storeBytes(of: 0, toByteOffset: length, as: CChar.self)
                let cPath = base.assumingMemoryBound(to: CChar.self)

                childProcess = try? context.processManager.pointee.spawnProcess(path: cPath)
            }

        }

        if let childProcess = childProcess {
            childProcess.pointee.family.parent = currentProcess
            currentProcess.pointee.family.pushChild(childProcess)

            let handleIPC = context.ipc.pointee.spawnEndpoint(
                for: currentProcess,
                and: childProcess
            )

            // Set on reg 1 the handle endpoint
            switch handleIPC {
                case .success(let success):
                    frame.pointee.x1 = UInt64(success)


                case .failure(_):
                    frame.pointee.x1 = UInt64(UInt32.max)
            }

            for i in 0..<grantsCount {
                context.ipc.pointee.injectCapability(
                    from  : currentProcess,
                    handle: grants[i].sourceHandle,
                    to    : childProcess,
                    slot  : grants[i].targetSlot,
                    rights: CapRights(rawValue: UInt16(truncatingIfNeeded: grants[i].rights))
                )
            }

            // Set on reg 0 the pid for parent process
            try? context.scheduler.pointee.addTask(childProcess)
            frame.pointee.x0 = childProcess.pointee.pid

        } else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = UInt64(UInt32.max)
        }
    }
}
