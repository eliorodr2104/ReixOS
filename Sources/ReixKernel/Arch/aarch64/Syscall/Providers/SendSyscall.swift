//
//  SendSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

public struct SendSyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .send

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let currentProcessAddress = Arch.CPU.getCurrentProcess()
        
        guard let currentProcess = UnsafeMutablePointer<Process>(
            bitPattern: UInt(currentProcessAddress)
        ) else { return }
        
        let handle   = frame.pointee.x0
        let metadata = currentProcess.pointee.metadata!
        guard let capability = metadata.pointee.capsTable.resolve(UInt32(handle)) else {
            frame.pointee.x0 = 0 // TODO: Error temp value, need create a const
            return
        }
        
        let resultSendMessage = context.ipc.pointee.send(
            capability: capability,
            frame     : frame.pointee
        )
        
        switch resultSendMessage {
            case .success(let successType):
                switch successType {
                    case .sended:
                        // TODO: OK temp value, need create a const
                        frame.pointee.x0 = 1
                        
                    case .blocked:
                        YieldSyscall.handle(frame: frame, context: context)
                    
                }
                
            case .failure(_):
                // TODO: Error temp value, need create a const
                frame.pointee.x0 = 0
        }
    }
}
