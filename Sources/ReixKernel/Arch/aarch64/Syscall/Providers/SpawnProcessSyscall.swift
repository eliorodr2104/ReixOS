//
//  SpawnProcessSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 29/05/2026.
//

public struct SpawnProcessSyscall: SyscallProvider {
    public static let number: SyscallNumber = .spawnProcess
    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        // TODO: Add first Eunuch control and add Error launch
        let currentRawProcess = Arch.CPU.getCurrentProcess()
        guard let currentProcess = UnsafeMutablePointer<Process>(bitPattern: UInt(currentRawProcess)),
              currentProcess.pointee.family.parent == nil else {
            return
        }
        
        // TODO: Add control pointer user space
        guard let source = UnsafeRawPointer(bitPattern: UInt(frame.pointee.x0)) else {
            return // throw .nullPointer
        }


        let length = Int(frame.pointee.x1)

        withUnsafeTemporaryAllocation(
            byteCount: length + 1,
            alignment: MemoryLayout<CChar>.alignment
        ) { buffer in
            let base = buffer.baseAddress!
            base.copyMemory(from: source, byteCount: length)
            base.storeBytes(of: 0, toByteOffset: length, as: CChar.self)
            let cPath = base.assumingMemoryBound(to: CChar.self)

            if let childProcess = try? context.processManager.pointee.spawnProcess(path: cPath) {
                childProcess.pointee.family.parent = currentProcess
                currentProcess.pointee.family.pushChild(childProcess)

                try? context.scheduler.pointee.addTask(childProcess)
                frame.pointee.x0 = childProcess.pointee.pid
            }
        }
    }
}
