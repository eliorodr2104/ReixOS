//
//  ReplyRecvSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

import ReixABI

public struct ReplyRecvSyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .replyRecv

    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else { return }
        
        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)
        guard let metadata = currentProcess.pointee.metadata else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }
        
        guard let capability = metadata.pointee.capsTable.resolve(handle) else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }
        
        let resultSendMessage = context.ipc.pointee.replyRecv(
            capability: capability,
            frame     : frame
        )
        
        switch resultSendMessage {
            case .success(let successType):
                switch successType {
                    case .sended(let grantRejected):
                        frame.pointee.x0 = grantRejected
                            ? IPCStatus.grantRejected.rawValue
                            : IPCStatus.ok.rawValue

                    case .blocked:
                        frame.pointee.x0 = IPCStatus.ok.rawValue
                        YieldSyscall.handle(frame: frame, context: context)
                    
                }
                
            case .failure(let error):
                // TODO: Error temp value, need create a const
                frame.pointee.x0 = error.status.rawValue
        }
    }
}
