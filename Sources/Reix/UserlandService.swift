//
//  UserlandService.swift
//  ReixOS
//
// Created by Eliomar Alejandro Rodriguez Ferrer on 28/06/2026.
//


import ReixABI


/// Base pattern for a userland server: it owns a service endpoint and handles
/// requests dispatched by operation. A conformer only implements `handle`; the
/// receive loop comes for free from the default `run()`.
public protocol UserlandService {
    associatedtype Operation: IPCLabel

    /// The endpoint clients send requests to.
    var serviceEndpoint: UInt32 { get }

    /// Handle one request. `request.badge` tells you who is calling.
    mutating func handle(_ operation: Operation, request: ReceivedMessage)
}


public extension UserlandService {

    /// Serve requests forever: receive, decode the operation, dispatch.
    ///
    /// An unknown operation is skipped rather than fatal — a server must not die
    /// because somebody sent it a label it does not know. But skipping it cannot
    /// mean dropping the message on the floor: if the sender attached a grant,
    /// the kernel has *already* installed that capability into this process's
    /// table, during the sender's `send` and before this loop ever saw the
    /// message.
    ///
    /// Every path out of a request that this loop declines to dispatch must give
    /// the grant back. A handler that *is* dispatched owns the capability and is
    /// responsible for it, `ConsoleServer.register` is the worked example.
    mutating func run() {
        
        while true {
            let request = receive(handle: serviceEndpoint)

            guard let operation = Operation(rawValue: request.message.tag.label) else {
                if let grantedCap = request.grantedCap { _ = capDrop(grantedCap) }
                continue
            }

            handle(operation, request: request)
        }
        
    }
}
