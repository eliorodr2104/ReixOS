//
//  SpawnServiceSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 04/06/2026.
//


import ReixABI

public struct SpawnServiceSyscall: SyscallProvider {

    public static let number: SyscallNumber = .spawnService

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        guard let current = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = UInt64(UInt32.max) // Error value
            return
        }

        guard let handler = current.pointee.metadata.pointee.capsTable.findFirst(for: .spawn) else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }
        
        frame.pointee.x0 = UInt64(handler)
    }
}
