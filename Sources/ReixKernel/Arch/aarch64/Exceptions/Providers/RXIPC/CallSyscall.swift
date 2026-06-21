//
//  CallSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

import ReixABI

public struct CallSyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .call

    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else { return }
        
        let handle   = frame.pointee.x0
        let metadata = currentProcess.pointee.metadata!
        guard let capability = metadata.pointee.capsTable.resolve(UInt32(handle)) else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }
        
        let resultSendMessage = context.ipc.pointee.call(
            capability: capability,
            frame     : frame.pointee
        )
        
        switch resultSendMessage {
            case .success(let successType):
                switch successType {
                    case .sended:
                        frame.pointee.x0 = IPCStatus.ok.rawValue
                        
                    case .blocked:
                        YieldSyscall.handle(frame: frame, context: context)
                    
                }
                
            case .failure(let error):
                // TODO: Error temp value, need create a const
                frame.pointee.x0 = error.status.rawValue
        }
    }
}
