//
//  ReceivedMessage.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//


public struct ReceivedMessage {
    public var message   : Message
    public var grantedCap: UInt32?

    /// Which process sent this.
    public var identity: UInt32

    /// Which conversation it belongs to. Sixty-four bits, so a server's token can
    /// carry more than one fact without either of them running out. See
    /// `IPCDelivery` for how the two travel.
    public var session: UInt64

    /// How the IPC itself went, which is a different question from what the
    /// message says.
    ///
    /// A server that answers "no such file" and a server that is not there any
    /// more are two different things, and only this tells them apart. It is the
    /// word the kernel leaves in the caller's frame, and it used to be thrown
    /// away: a reply that never came was read as though it had.
    public var status: IPCStatus

    /// Whether there is really a message here.
    ///
    /// `false` and the message is `Message.unanswered`, not the reply that
    /// never came and not the request that went out. Nothing in `message` is
    /// worth reading, and everything that reads it is built to say so.
    public var arrived: Bool { status.isDelivered }

    init(
        message      : Message,
        sessionWord  : UInt64,
        principalWord: UInt64,
        status       : IPCStatus = .ok
    ) {
        self.status  = status
        self.message = status.isDelivered ? message : Message.unanswered

        self.grantedCap = status.isDelivered
            ? IPCDelivery.grant(of: principalWord)
            : nil

        self.identity = IPCDelivery.identity(of: principalWord)
        self.session  = sessionWord
    }


    /// Whether this is an interrupt notification the kernel wrote.
    ///
    /// The one door, so no driver has to remember that the label is not the
    /// check. See `InterruptNotification.fromKernel`.
    public var isInterruptNotification: Bool {
        InterruptNotification.fromKernel(
            tag       : message.tag,
            identity  : identity,
            session   : session,
            grantedCap: grantedCap
        )
    }


    /// The interrupt this message is, or nothing when it is not one the kernel
    /// wrote. See `KernelInterrupt`.
    public var kernelInterrupt: KernelInterrupt? {
        guard isInterruptNotification else { return nil }

        return KernelInterrupt(lines: InterruptNotification.lines(of: message))
    }


    /// Take ownership of the granted capability, leaving nothing attached.
    ///
    /// The kernel installs a grant into this process's table during the *sender's*
    /// `send`, so by the time a handler runs the slot is already spent whether the
    /// handler wants it or not. `UserlandService.run()` gives back whatever is
    /// still attached once the handler returns, which only works if keeping a
    /// capability is something the handler has to *say*: call this and it is
    /// yours, ignore it and the loop returns it for you.
    ///
    /// Reading `grantedCap` directly is still fine to *inspect* a grant while
    /// deciding, take it only at the point of no return.
    public mutating func takeGrant() -> UInt32? {
        defer { grantedCap = nil }
        return grantedCap
    }
}
