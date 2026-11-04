//
//  BlockQueue.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// How many block requests one client may have in flight, and how they are told
/// apart.
///
/// The number has to be the same in four places - the driver's descriptor
/// chains, the server's outstanding table, the pages of the client's window, and
/// the file system's record of what it asked for - so it lives in one.
///
/// A request is named by a **slot**, and the slot is not only a name: it is also
/// the page of the shared window that request's bytes travel through. One number
/// for both, because two would be two numbers that have to agree, and the four
/// words of a message are spoken for.
public enum BlockQueue {

    /// Requests in flight per client.
    ///
    /// Four, matching the driver's chains. More would need a bigger window in
    /// every client and buys nothing until something can produce more than four
    /// at once.
    public static let depth = 4

    /// The slot value that means "nothing was outstanding", in the answer to a
    /// `collect` from a client that has asked for nothing.
    public static let none: UInt32 = UInt32.max

    /// Whether `slot` is one a client may name.
    public static func valid(_ slot: UInt32) -> Bool {
        slot < UInt32(depth)
    }

    /// Where `slot`'s bytes sit in a window of `depth` pages.
    public static func offset(
        of slot    : UInt32,
           pageSize: UInt64
    
    ) -> UInt64 { UInt64(slot) * pageSize }
}
