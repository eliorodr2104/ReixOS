//
//  ReplySyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


import ReixABI

/// `reply(identity, tag, w0, w1, w2, w3, grantWord)` syscall provider.
///
/// `identity` in `x0` says which caller to answer, and zero means the newest.
/// Zero is what the register already held - the reply target used to be implicit
/// - so every server written before this keeps working without a change, and
/// zero is also the wire value for "no identity", so it can never name anybody.
///
/// A server holding several requests names one. The name is the caller's
/// identity, which arrives with every request and which every server keeping
/// per-client state is already keyed on, so nothing new has to be carried
/// around to be able to answer late.
public struct ReplySyscall: SyscallProvider {
    
    public static let number: SyscallNumber = .reply

    
    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        var target: UnsafeMutablePointer<Process>? = nil

        if frame.pointee.x0 != 0 {
            guard frame.pointee.x0 <= UInt64(Badge.max),
                  let current = Arch.CPU.getCurrentProcess(),
                  let waiter  = RendezvousIPC.waiter(
                      identity: Badge(truncatingIfNeeded: frame.pointee.x0),
                      on      : current
                  )
            else {
                // Nobody by that name is waiting on this process. Refused rather
                // than falling back to the newest caller: a server that named the
                // wrong client must not have its words delivered to a different
                // one, which is exactly the mix-up an implicit target invites.
                frame.pointee.x0 = IPCStatus.noReply.rawValue
                return
            }

            target = waiter
        }

        let resultSendMessage = context.ipc.pointee.reply(
            frame : frame.pointee,
            target: target
        )
        
        switch resultSendMessage {
            case .success(let successType):
                switch successType {
                    
                    case .sended(let grantRejected):
                        frame.pointee.x0 = grantRejected
                            ? IPCStatus.grantRejected.rawValue
                            : IPCStatus.ok.rawValue

                    case .blocked: break
                }
                
            case .failure(let error):
                // TODO: Error temp value, need create a const
                frame.pointee.x0 = error.status.rawValue
        }
    }
}
