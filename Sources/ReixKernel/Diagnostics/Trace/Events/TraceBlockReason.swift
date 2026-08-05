//
//  TraceBlockReason.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.
//


/// Why a process parked, carried in `TraceCode.ipcBlock`'s `info`.
internal enum TraceBlockReason {

    /// `send` found no receiver waiting and queued the sender.
    static let sendQueue: UInt16 = 0

    /// `receive` found no message and queued the receiver.
    static let recvWait: UInt16 = 1

    /// `call` parked its caller, either behind the send queue or on the reply.
    static let call: UInt16 = 2
}
