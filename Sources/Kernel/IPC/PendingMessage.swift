//
//  PendingMessage.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//

import ReixABI


/// A message a sender left on an endpoint nobody was waiting on.
///
/// ## The attachment is the authority, not the slot number
///
/// This used to hold the sender's *handle* and resolve it when the message was
/// finally collected, which can be arbitrarily later. Everything about the
/// sender's table could change in between: the slot dropped, the slot reused
/// for something else, the sender dead and its whole table released. A message
/// naming slot three delivered the slot three of the moment it was read, and if
/// nothing else held the region, the region was already gone.
///
/// So the send resolves the handle once, attenuates the rights once, and takes
/// a reference on the target, exactly as installing the capability in a table
/// does. What is parked here is the capability itself. Delivery installs it and
/// hands the reference to the receiver's table; a delivery that fails, or a
/// sender that dies parked, gives the reference back. See
/// `RendezvousIPC.holdForTransfer` and `retirePending`.
///
/// ## Where it lives
///
/// In `ProcessMetadata`, not in `Process`. Holding a whole `Capability` costs
/// twenty-four bytes and `Process` had six to spare inside the 256 byte slab
/// bucket it has to stay in; the cold block had a hundred and twenty inside its
/// own. A parked message is cold by definition - the process is asleep - and
/// every path that touches it already has the metadata pointer in hand.
/// `Process.pending` still reads and writes it, so no call site knows.
public struct PendingMessage {

    public let session     : Badge        // 8 Byte
    public let message     : Message      // 24 Byte

    /// The capability this message carries, already resolved and attenuated,
    /// with one reference held on its target for as long as it sits here.
    public let grant       : Capability?  // 24 Byte

    /// Whether the send named an attachment the sender could not hand over.
    ///
    /// Recorded rather than answered on the spot so the sender sees the same
    /// `grantRejected` it always did, at the same moment: when the message is
    /// collected. A blocking send has already returned `.blocked` by then.
    public let grantRejected: Bool        // 1 Byte

    public let expectsReply : Bool        // 1 Byte


    public init(
        message      : Message,
        session      : Badge,
        grant        : Capability?,
        grantRejected: Bool,
        expectsReply : Bool
    ) {
        self.message       = message
        self.session       = session
        self.grant         = grant
        self.grantRejected = grantRejected
        self.expectsReply  = expectsReply
    }
}
