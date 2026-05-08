//
//  SyscallHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//


public struct SyscallHandler {

    public static func handleExit(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
                
        let currentAddr = Arch.CPU.getCurrentProcess()
        if let current = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {
            current.pointee.context?.pointee = frame.pointee
            current.pointee.status = .terminated
            
            do {
                Arch.CPU.setCurrentProcess(0)
                try ProcessManager.destroyProcess(current)
                
            } catch {
                Arch.CPU.panic("Failed to destroy exiting process")
            }
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
            while true {
                Arch.CPU.waitForInterrupt()
            }
        }
    }

    public static func handleYield(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
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

    public static func handleDebugPrint(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        let userBufferAddr = frame.pointee.x0
        let length         = frame.pointee.x1

        if let ptr = UnsafePointer<UInt8>(bitPattern: UInt(userBufferAddr)) {
            for i in 0..<Int(length) {
                kputc(ptr.advanced(by: i).pointee)
            }
            kprint()
        }
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

            case .debugPrint:
                handleDebugPrint(frame: frame)
        }
    }
}
