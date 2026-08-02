//
//  TrySendSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 01/06/2026.
//

import ReixABI

public struct TrySendSyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .trySend

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }
        
        let handle   = UInt32(truncatingIfNeeded: frame.pointee.x0)
        let metadata = currentProcess.pointee.metadata!
        guard let capability = metadata.pointee.capsTable.resolve(handle) else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }
        
        let resultSendMessage = context.ipc.pointee.send(
            capability: capability,
            frame     : frame.pointee,
            blocking  : false
        )
        
        switch resultSendMessage {
            case .success(let successType):
                switch successType {
                    
                    case .sended(let grantRejected):
                        frame.pointee.x0 = grantRejected
                            ? IPCStatus.grantRejected.rawValue
                            : IPCStatus.ok.rawValue

                    case .blocked:
                        frame.pointee.x0 = IPCStatus.wouldBlock.rawValue
                }
                
            case .failure(let error):
                frame.pointee.x0 = error.status.rawValue
        }
    }
}
