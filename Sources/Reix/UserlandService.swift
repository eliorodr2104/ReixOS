//
//  UserlandService.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/06/2026.
//


import ReixABI


/// Base pattern for a userland server: it owns a service endpoint and handles
/// requests dispatched by operation. A conformer only implements `handle`; the
/// receive loop comes for free from the default `run()`.
public protocol UserlandService {
    associatedtype Operation: IPCLabel

    /// The endpoint clients send requests to.
    var serviceEndpoint: UInt32 { get }

    /// Handle one request. `request.identity` tells you who is calling.
    ///
    /// `request` is `inout` so that `takeGrant()` is visible to the loop: keep an
    /// attached capability by taking it, and anything left behind is released for
    /// you. Nothing else about the message is meant to be written.
    mutating func handle(_ operation: Operation, request: inout ReceivedMessage)
}


public extension UserlandService {

    mutating func run() {

        while true {
            var request = receive(handle: serviceEndpoint)

            if let operation = Operation(rawValue: request.message.tag.label) {
                handle(operation, request: &request)
            }

            if let grantedCap = request.takeGrant() { _ = capDrop(grantedCap) }
        }

    }
}
