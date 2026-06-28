//
//  IPCInterface.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public protocol IPCInterface: RXAllocatable {
    
    mutating func send(
        capability: Capability,
        frame     : AArch64.TrapFrame,
        blocking  : Bool
    ) -> Result<CommunicationMessageResult, IPCError> // Send mess, block if not receive the mess
    
    mutating func receive(
        capability  : Capability,
        frame       : UnsafeMutablePointer<AArch64.TrapFrame>,
        blocking    : Bool,
        timeoutTicks: UInt64?
    ) -> Result<CommunicationMessageResult, IPCError> // wait, block if not send mess
    
    mutating func call(
        capability: Capability,
        frame     : AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> // send + wait-reply, is atomic
    
    mutating func reply(
        frame: AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> // Server respond to call process
    
    mutating func replyRecv(
        capability: Capability,
        frame     : UnsafeMutablePointer<AArch64.TrapFrame>
    ) -> Result<CommunicationMessageResult, IPCError> // reply + receive fuse (server loop)
}
