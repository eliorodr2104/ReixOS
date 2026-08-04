//
//  ReceiveTimeoutSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 01/06/2026.
//

import ReixABI

public struct ReceiveTimeoutSyscall: SyscallProvider {

    public static let number: SyscallNumber = .receiveTimeout

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }

        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)
        let ticks  = frame.pointee.x1

        guard let metadata = currentProcess.pointee.metadata else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }

        guard let capability = metadata.pointee.capsTable.resolve(handle) else {
            frame.pointee.x0 = IPCStatus.invalidCapability.rawValue
            return
        }

        let resultReceiveMessage = context.ipc.pointee.receive(
            capability  : capability,
            frame       : frame,
            blocking    : true,
            timeoutTicks: ticks
        )

        switch resultReceiveMessage {
            case .success(let successType):
                switch successType {
                    case .sended:
                        frame.pointee.x0 = IPCStatus.ok.rawValue

                    case .blocked:
                        frame.pointee.x0 = IPCStatus.ok.rawValue
                        YieldSyscall.handle(frame: frame, context: context)
                }

            case .failure(let failType):
                frame.pointee.x0 = failType.status.rawValue
        }
    }
}
