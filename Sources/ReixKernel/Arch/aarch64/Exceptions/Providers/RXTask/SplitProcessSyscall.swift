//
//  SplitProcessSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import ReixABI

public struct SplitProcessSyscall: SyscallProvider {
    public static let number: SyscallNumber = .split
    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess(),
              currentProcess.pointee.family.parent == nil else {
            frame.pointee.x0 = UInt64.max
            return // throw .eunuch
        }


        guard let childProcess = try? context.processManager.pointee.spawnProcess() else {
            frame.pointee.x0 = UInt64.max
            return
        }

        childProcess.pointee.context!.pointee    = frame.pointee
        childProcess.pointee.context!.pointee.x0 = 0

        let childMetadata  = childProcess.pointee.metadata!
        let parentMetadata = currentProcess.pointee.metadata!

        childMetadata.pointee.elfImage     = nil
        childMetadata.pointee.elfLoadBase  = parentMetadata.pointee.elfLoadBase
        childMetadata.pointee.elfLoadEnd   = parentMetadata.pointee.elfLoadEnd
        childMetadata.pointee.programBreak = parentMetadata.pointee.programBreak

        context.ipc.pointee.cloneCapsTable(from: parentMetadata, to: childMetadata)

        guard let childVMM  = childProcess.pointee.addressSpace.vmaManager,
              let parentVMM = currentProcess.pointee.addressSpace.vmaManager
        else {
            discard(childProcess, context: context)
            frame.pointee.x0 = UInt64.max

            return
        }

        childVMM.pointee.setInitialBreak(parentVMM.pointee.currentBreak)

        do {
            try childVMM.pointee.cloneRegions(from: parentVMM.pointee)

        } catch {
            discard(childProcess, context: context)
            frame.pointee.x0 = UInt64.max

            return
        }

        childProcess.pointee.family.parent = currentProcess
        currentProcess.pointee.family.pushChild(childProcess)
        try? context.scheduler.pointee.addTask(childProcess)

        frame.pointee.x0 = childProcess.pointee.pid
    }

    private static func discard(
        _ child: UnsafeMutablePointer<Process>,
        context: SyscallContext
    ) {
        guard context.processManager.pointee.killProcess(
            child,
            reason : .killed,
            context: context
        ) else { return }

        _ = context.scheduler.pointee.reapChild(child)
        context.processManager.pointee.releaseProcess(child)
    }
}
