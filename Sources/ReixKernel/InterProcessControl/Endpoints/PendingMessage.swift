//
//  PendingMessage.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//

import ReixABI


/// A message a sender left on an endpoint nobody was waiting on.
///
/// The session leads and the rest follows, which is not style. It is eight bytes
/// wide and eight-byte aligned since sessions widened, so putting it after the
/// twenty-one byte message costs three bytes of padding in front of it - and this
/// struct is stored inside `Process`, which is kmalloc'ed per process and has to
/// stay inside the 256 byte slab bucket.
public struct PendingMessage {

    public let session     : Badge     // 8 Byte
    public let message     : Message   // 24 Byte
    public let grant       : UInt32    // 4 Byte
    public let rights      : CapRights // 2 Byte
    public let expectsReply: Bool      // 1 Byte

    /// The handle, or nil when nothing was attached.
    ///
    /// Stored as the sentinel the wire already uses rather than as an optional,
    /// which is not a micro-optimisation: an `Optional<UInt32>` is five bytes, and
    /// five bytes here rounds this struct up to a forty-eight byte stride, and
    /// that is what pushes `Process` out of the 256 byte slab bucket.
    public var attachment: UInt32? {
        grant == IPCDelivery.noGrant ? nil : grant
    }


    public init(
        message     : Message,
        session     : Badge,
        grant       : UInt32?,
        rights      : CapRights,
        expectsReply: Bool
    ) {
        self.message      = message
        self.session      = session
        self.grant        = grant ?? IPCDelivery.noGrant
        self.rights       = rights
        self.expectsReply = expectsReply
    }
}
