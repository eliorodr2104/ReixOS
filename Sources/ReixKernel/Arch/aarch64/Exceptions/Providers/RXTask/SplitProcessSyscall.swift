//
//  SplitProcessSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public struct SplitProcessSyscall: SyscallProvider {
    public static let number: SyscallNumber = .split
    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        // TODO: Add first Eunuch control and add Error launch
        let currentRawProcess = Arch.CPU.getCurrentProcess()
        guard let currentProcess = UnsafeMutablePointer<Process>(bitPattern: UInt(currentRawProcess)),
              currentProcess.pointee.family.parent == nil else {
            return // throw .eunuch
        }


        if let childProcess = try? context.processManager.pointee.spawnProcess() {
            childProcess.pointee.family.parent = currentProcess
            
            childProcess.pointee.context!.pointee = frame.pointee

            childProcess.pointee.context!.pointee.x0 = 0
            
            // Set metadata parent
            let childMetadata  = childProcess.pointee.metadata!
            let parentMetadata = currentProcess.pointee.metadata!
            
            // The child's pages are private anonymous copies, released
            // per-page by `VMAManager.teardown`. It must NOT inherit — and
            // later free — the parent's shared contiguous ELF image block,
            // or teardown would double-free it.
            childMetadata.pointee.elfImage     = nil
            childMetadata.pointee.elfLoadBase  = parentMetadata.pointee.elfLoadBase
            childMetadata.pointee.elfLoadEnd   = parentMetadata.pointee.elfLoadEnd
            childMetadata.pointee.programBreak = parentMetadata.pointee.programBreak
            
            // Clone Endpoint Table into Metadata Struct
            childMetadata.pointee.capsTable = parentMetadata.pointee.capsTable

            
            let childVMM  = childProcess.pointee.addressSpace.vmaManager
            let parentVMM = currentProcess.pointee.addressSpace.vmaManager
                    
            childVMM?.pointee.setInitialBreak(parentVMM!.pointee.currentBreak)
            
            do {
                try childVMM?.pointee.cloneRegions(from: parentVMM!.pointee)
                
            } catch {
                frame.pointee.x0 = UInt64(0xFFFFFFFFFFFFFFFF) // Create error code
                return
            }
            
            
            currentProcess.pointee.family.pushChild(childProcess)
            try? context.scheduler.pointee.addTask(childProcess)
                    
            frame.pointee.x0 = childProcess.pointee.pid
        }
    }
}
