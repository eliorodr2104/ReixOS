//
//  ReceivedMessage.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//

public struct ReceivedMessage {
    public var message   : Message
    public var grantedCap: UInt32?
    public var identity: UInt32
    public var session: UInt32

    init(
        message   : Message,
        grantedCap: UInt32,
        badgeWord : UInt64
    ) {
        self.message    = message
        self.grantedCap = grantedCap == UInt32.max ? nil : UInt32(grantedCap)

        self.identity   = UInt32(truncatingIfNeeded: badgeWord >> 32)
        self.session    = UInt32(truncatingIfNeeded: badgeWord)
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
