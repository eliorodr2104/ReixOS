//
//  ReceiveTimeoutSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 01/06/2026.
//

public struct ReceiveTimeoutSyscall: SyscallProvider {

    public static let number: SyscallNumber = .receiveTimeout

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let currentProcess = Arch.CPU.getCurrentProcess() else { return }

        let handle   = frame.pointee.x0
        let ticks    = frame.pointee.x1
        let metadata = currentProcess.pointee.metadata!

        guard let capability = metadata.pointee.capsTable.resolve(UInt32(handle)) else {
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
                        YieldSyscall.handle(frame: frame, context: context)
                }

            case .failure(let failType):
                frame.pointee.x0 = failType.status.rawValue
        }
    }
}
