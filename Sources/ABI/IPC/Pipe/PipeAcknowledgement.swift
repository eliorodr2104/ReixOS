//
//  PipeAcknowledgement.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct PipeAcknowledgement {
    public let count: UInt32
    public let status: PipeStatus
    public let flags: UInt32
    public let token: UInt32

    public init(count: UInt32, status: PipeStatus, flags: UInt32, token: UInt32 = 1) {
        self.count = count
        self.status = status
        self.flags = flags
        self.token = token
    }

    public func accepts(_ frame: PipeFrame) -> Bool {
        status == .ok && count == frame.count && flags == frame.flags && token == frame.token
    }
}
