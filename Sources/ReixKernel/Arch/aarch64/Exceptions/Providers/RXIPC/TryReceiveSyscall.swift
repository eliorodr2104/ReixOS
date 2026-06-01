//
//  TryReceiveSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 01/06/2026.
//

public struct TryReceiveSyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .tryReceive

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
        
        let resultSendMessage = context.ipc.pointee.receive(
            capability: capability,
            frame     : frame,
            blocking  : false
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
                frame.pointee.x0 = error.status.rawValue
        }
    }
}
