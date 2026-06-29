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
              let _              = currentProcess.pointee.metadata.pointee.capsTable.findFirst(for: .spawn) else {
            return
        }
        
        // TODO: Add control pointer user space
        guard let source = UnsafeRawPointer(bitPattern: UInt(frame.pointee.x0)) else {
            return // throw .nullPointer
        }


        let length = Int(frame.pointee.x1)

        var grants      = InlineArray<8, CapGrant>(repeating: CapGrant())
        var grantsCount = 0

        if let grantsBase = UnsafeRawPointer(bitPattern: UInt(frame.pointee.x2)),
           frame.pointee.x3 > 0 {
            let count = min(Int(frame.pointee.x3), grants.count)
            let typed = grantsBase.assumingMemoryBound(to: CapGrant.self)

            for i in 0..<count { grants[i] = typed[i] }
            grantsCount = count
        }

        var childProcess: UnsafeMutablePointer<Process>?

        if length != 0 {
            withUnsafeTemporaryAllocation(
                byteCount: length + 1,
                alignment: MemoryLayout<CChar>.alignment
            ) { buffer in
                let base = buffer.baseAddress!
                base.copyMemory(from: source, byteCount: length)
                base.storeBytes(of: 0, toByteOffset: length, as: CChar.self)
                let cPath = base.assumingMemoryBound(to: CChar.self)

                childProcess = try? context.processManager.pointee.spawnProcess(path: cPath)
            }
            
        } else { childProcess =  try? context.processManager.pointee.spawnProcess() }
        
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
                    rights: CapRights(rawValue: UInt8(truncatingIfNeeded: grants[i].rights))
                )
            }

            // Set on reg 0 the pid for parent process
            try? context.scheduler.pointee.addTask(childProcess)
            frame.pointee.x0 = childProcess.pointee.pid
        }
    }
}
