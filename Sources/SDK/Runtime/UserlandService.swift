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
    ///
    /// Answering is this method's business, and so is *not* answering. A server
    /// that cannot finish yet may simply return without replying: the caller
    /// stays parked, and `reply(message:to:)` reaches it later by the identity it
    /// arrived with. Nothing here answers on its behalf.
    mutating func handle(_ operation: Operation, request: inout ReceivedMessage)

    /// A line this server's device raised, for a server that bound an interrupt
    /// set to its endpoint with `irqBind`.
    ///
    /// The argument is `KernelInterrupt` and not a bit set, which is what makes
    /// the origin unskippable: the only way to have one is to have been handed a
    /// message the kernel wrote. Servers that drive no hardware never see one and
    /// need not implement this.
    mutating func handle(interrupt fired: KernelInterrupt)

    /// The receive loop. Defaulted below, and a requirement anyway.
    ///
    /// A requirement because of how Swift dispatches: `ServiceRuntime.run` calls
    /// this through a generic parameter, and a method that exists only in a
    /// protocol *extension* is resolved statically there - so a conformer that
    /// wrote its own would have watched the default one run instead. Naming it
    /// here is what makes the override reachable.
    ///
    /// A server overrides this when the loop itself has to do something: the block
    /// server waits with a deadline, because a device that never answers must not
    /// park the process that drives it for ever.
    mutating func run()
}


public extension UserlandService {

    /// Nothing, for the servers that drive no hardware.
    mutating func handle(interrupt fired: KernelInterrupt) {}

    mutating func run() {

        while true {
            var request = receive(handle: serviceEndpoint)

            // One wait, two kinds of news. A driver that bound its interrupt set
            // to this endpoint hears its device here, in the same place it hears
            // its clients, which is the whole reason it can hold a request open
            // while the disk is busy instead of blocking inside it.
            // The label is not the check. A process holding a capability to this
            // endpoint may send any label it likes, so the origin is what says
            // this came from a device. See `KernelInterrupt`.
            if let fired = request.kernelInterrupt {
                handle(interrupt: fired)

            } else if request.identity == InterruptNotification.kernelIdentity {
                // From no process, and not a notification. Nothing to serve and
                // nobody to answer.
                continue

            } else if let operation = Operation(rawValue: request.message.tag.label) {
                handle(operation, request: &request)
            }

            if let grantedCap = request.takeGrant() { _ = capDrop(grantedCap) }
        }

    }
}
