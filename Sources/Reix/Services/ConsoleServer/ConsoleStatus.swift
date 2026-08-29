//
//  ConsoleStatus.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//

import ReixABI

/// Payload of the `flush` reply: whether the server still holds a ring for the
/// caller.
///
/// A client that is *not* registered has to stop pushing into its ring, nobody
/// will ever drain it, so waiting for a free slot is a livelock, and print
/// through the kernel instead.
public enum ConsoleStatus: UInt32 {
    case unregistered = 0
    case registered   = 1

    /// Pending serial work still owns the bytes and keeps the ring registered.
    public static func afterSerialFlush(
        hasRing: Bool,
        flush  : ReixSerialStatus
    ) -> ConsoleStatus {

        guard hasRing else { return .unregistered }

        _ = flush
        return .registered
    }
}
