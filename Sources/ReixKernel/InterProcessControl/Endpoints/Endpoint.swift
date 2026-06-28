//
//  Endpoint.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import ReixABI

public typealias Badge = UInt32

public struct Endpoint: RXObject {
    
    public static var errorMessageAllocation: StaticString = "Failed to allocate IPC endpoint"
    public static var kernelOwner           : PID    = PID.max
    
    public var queue     : LinkedList<Process>   // 8 Byte
    public var references: UInt32        = 0     // 4 Byte
    public var state     : EndpointState = .idle // 1 Byte

    public init(queue: LinkedList<Process>) {
        self.queue = queue
    }
}
