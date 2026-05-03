//
//  SyscallHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//


public struct SyscallHandler {
    
    public static func handle(
        type: SyscallNumber,
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        switch type {
            case .exit:
                let exitCode = UInt64(frame.pointee.x0)
                kprint("Process exited with code: ")
                kprint(exitCode)
                // Kernel.processManager.terminateCurrent()

            case .yield:
                if let trapFrame = Kernel.scheduler.yield() {
                    frame.pointee = trapFrame.pointee
                }

            case .debugPrint:
                let userBufferAddr = frame.pointee.x0
                let length         = frame.pointee.x1
                
                if let ptr = UnsafePointer<UInt8>(bitPattern: UInt(userBufferAddr)) {
                    let buffer = UnsafeBufferPointer(start: ptr, count: Int(length))
                    
                    let s = String(decoding: buffer, as: UTF8.self)
                    kprint(s)
                }
        }
    }
}
