//
//  ReplySyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


public struct ReplySyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .reply

    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let resultSendMessage = context.ipc.pointee.reply(
            frame: frame.pointee
        )
        
        switch resultSendMessage {
            case .success(let successType):
                switch successType {
                    case .sended:
                        // TODO: OK temp value, need create a const
                        frame.pointee.x0 = IPCStatus.ok.rawValue
                        
                    case .blocked: break
                }
                
            case .failure(let error):
                // TODO: Error temp value, need create a const
                frame.pointee.x0 = error.status.rawValue
        }
    }
}
