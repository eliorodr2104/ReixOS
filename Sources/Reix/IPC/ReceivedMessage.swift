//
//  ReceivedMessage.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//

public struct ReceivedMessage {
    public var message   : Message
    public var grantedCap: UInt32?

    /// Who sent this, as attested by the kernel.
    ///
    /// Assigned to the sending process at creation and unforgeable from userland:
    /// it does not live in any capability, so no grant, copy or fork can hand it
    /// to somebody else. `0` means "no identity" and names no live process.
    public var identity: UInt32

    /// Which conversation this belongs to — the badge bound to the capability the
    /// sender used, `0` when that capability is unbadged. Says nothing about who
    /// the sender is; use `identity` for that.
    public var session: UInt32

    init(
        message   : Message,
        grantedCap: UInt32,
        badgeWord : UInt64
    ) {
        self.message    = message
        self.grantedCap = grantedCap == UInt32.max ? nil : UInt32(grantedCap)

        // Split once, here, so no caller has to know the layout of `x6`. Both
        // halves are 32-bit wide, so neither loses a bit.
        self.identity   = UInt32(truncatingIfNeeded: badgeWord >> 32)
        self.session    = UInt32(truncatingIfNeeded: badgeWord)
    }
}
