//
//  IPCInterface.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public protocol IPCInterface: RXObject {
    
    mutating func send(
        capability: EndpointCap,
        frame     : AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> // Send mess, block if not receive the mess
    
    mutating func receive(
        capability: EndpointCap,
        frame     : UnsafeMutablePointer<AArch64.TrapFrame>
    ) -> Result<CommunicationMessageResult, IPCError> // wait, block if not send mess
    
    mutating func call(
        capability: EndpointCap,
        frame     : AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> // send + wait-reply, is atomic
    
    mutating func reply(
        frame: AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> // Server respond to call process
    
    mutating func replyRecv() // reply + receive fuse (server loop)
}
