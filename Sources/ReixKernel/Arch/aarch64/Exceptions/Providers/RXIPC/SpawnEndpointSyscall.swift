//
//  SpawnEndpointSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


public struct SpawnEndpointSyscall: SyscallProvider {

    public static let number: SyscallNumber = .spawnEndpoint

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let currentAddress = Arch.CPU.getCurrentProcess()
        guard let current = UnsafeMutablePointer<Process>(
            bitPattern: UInt(currentAddress)
            
        ) else {
            frame.pointee.x0 = UInt64(UInt32.max) // Error value
            return
        }

        switch context.ipc.pointee.spawnEndpoint(for: current) {
            case .success(let handle):
                frame.pointee.x0 = UInt64(handle)

            case .failure(_):
                frame.pointee.x0 = UInt64(UInt32.max) // Error value 
        }
    }
}
