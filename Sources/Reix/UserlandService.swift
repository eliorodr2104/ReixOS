//
//  UserlandService.swift
//  ReixOS
//
//  Base pattern for a userland server: it owns a service endpoint and handles
//  requests dispatched by operation. A conformer only implements `handle`; the
//  receive loop comes for free from the default `run()`.
//

import ReixABI

public protocol UserlandService {
    associatedtype Operation: IPCLabel

    /// The endpoint clients send requests to.
    var serviceEndpoint: UInt32 { get }

    /// Handle one request. `request.badge` tells you who is calling.
    mutating func handle(_ operation: Operation, request: ReceivedMessage)
}


public extension UserlandService {

    /// Serve requests forever: receive, decode the operation, dispatch.
    /// Unknown operations are skipped (they don't kill the server).
    mutating func run() {
        while true {
            let request = receive(handle: serviceEndpoint)

            guard let operation = Operation(rawValue: request.message.tag.label) else {
                continue
            }

            handle(operation, request: request)
        }
    }
}
