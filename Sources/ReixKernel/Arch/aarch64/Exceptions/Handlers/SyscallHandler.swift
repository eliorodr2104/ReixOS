//
//  SyscallHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//


public struct SyscallHandler {

    private static func handleExit(
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        
        let currentAddr = Arch.CPU.getCurrentProcess()
        if let oldProcess = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {
            oldProcess.pointee.context?.pointee = frame.pointee
            oldProcess.pointee.status           = .terminated
            
            do {
                Arch.CPU.setCurrentProcess(0)
                try ProcessManager.releaseAddressSpace(oldProcess)
                
            } catch { Arch.CPU.panic("Failed to destroy exiting process") }
            
            oldProcess.pointee.exitCode = UInt32(frame.pointee.x0)
            Kernel.scheduler.removeTask(oldProcess)
        }
        
        // Change Process
        if let trapFrame = Kernel.scheduler.yield() {
            let nextAddr = Arch.CPU.getCurrentProcess()
            if let next = UnsafeMutablePointer<Process>(bitPattern: UInt(nextAddr)) {
                Arch.MMU.switchUserAddressSpace(next.pointee.addressSpace.rootTablePhysical.address)
            }
            
            frame.pointee = trapFrame.pointee
            
        } else {
            Arch.CPU.setCurrentProcess(0)
            while true { Arch.CPU.waitForInterrupt() }
        }
        
//        if oldProcess != nil {
//            oldProcess!.deinitialize(count: 1)
//            KernelHeap.kfree(UnsafeMutableRawPointer(oldProcess!))
//        }
    }
    

    private static func handleYield(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        let currentAddr = Arch.CPU.getCurrentProcess()
        if let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {
            current.pointee.context?.pointee = frame.pointee
        }

        if let trapFrame = Kernel.scheduler.yield() {
            let nextAddr = Arch.CPU.getCurrentProcess()
            
            if let next = UnsafeMutablePointer<Process>(bitPattern: UInt(nextAddr)) {
                Arch.MMU.switchUserAddressSpace(next.pointee.addressSpace.rootTablePhysical.address)
            }
            
            frame.pointee = trapFrame.pointee
        }
    }
    

    public static func handlePutchar(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        kputc(UInt8(frame.pointee.x0))
    }
    
    
    private static func handleGetPID(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        let currentRawProcess = Arch.CPU.getCurrentProcess()
        if let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentRawProcess)) {
            frame.pointee.x0 = UInt64(current.pointee.pid)
            
        } else { frame.pointee.x0 = 0 }
    }
    
    // TODO: - Create a ExitCode standard, zero val is a temp not found
    private static func handleReapChild(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        let childPid = frame.pointee.x0
        
        if let child = Kernel.scheduler.search(in: .waiting, to: childPid) {
            let currentPtr = Arch.CPU.getCurrentProcess()
            
            // TODO: - Add throws for all case
            guard let parent  = child.pointee.parent,
                  let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentPtr)),
                  parent.pointee.pid == current.pointee.pid
            else {
                return
            }
                        
            if !Kernel.scheduler.reapChild(child) {
                // Block process, this waiting child died
                // Manage error, temp is try? and not block the kernel
                try? Kernel.scheduler.block(current.pointee.pid)
                handleYield(frame: frame)
            }
            
            frame.pointee.x0 = UInt64(child.pointee.exitCode ?? 0)
            return
        }
        
        frame.pointee.x0 = 0
    }
    
    
    public static func handle(
        type: SyscallNumber,
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        switch type {
            case .exit:
                handleExit(frame: frame)

            case .yield:
                handleYield(frame: frame)

            case .putchar:
                handlePutchar(frame: frame)
                
            case .getPid:
                handleGetPID(frame: frame)
                
            case .reapChild:
                handleReapChild(frame: frame)
                
            default:
                break
        }
    }
}
