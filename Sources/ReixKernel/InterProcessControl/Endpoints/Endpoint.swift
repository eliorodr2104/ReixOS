//
//  Endpoint.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import ReixABI

/// A session token, sixty-four bits wide.
///
/// It was thirty-two, and the width was the ceiling on how long a server could go
/// before handing out a token it had used before. What made it worth widening is
/// the file system's own badge: that one carries an object number, a generation
/// and eight rights bits, and thirty-two bits between the three of them meant the
/// generation ran out after a few million reuses of one slot. See `FSBadge`.
public typealias Badge = UInt64

/// A sender's principal: which process a message came from.
///
/// A counter over the life of the machine, so a word is a hundred years of
/// spawning. Kept apart from `Badge` because they answer different questions and
/// now travel in different registers: this one says *who*, a badge says *which
/// conversation*.
public typealias Identity = UInt32

public struct Endpoint: RXObject {
    
    public static var errorMessageAllocation: StaticString = "Failed to allocate IPC endpoint"
    public static var kernelOwner           : PID    = PID.max
    
    public var queue     : LinkedList<Process>   // 16 Byte
    public var references: UInt32        = 0     // 4 Byte
    public var state     : EndpointState = .idle // 1 Byte

    /// How many live capabilities on this endpoint carry `.receive`.
    ///
    /// The nearest thing an endpoint has to an owner, and the reason it is a
    /// count rather than a pointer: an endpoint really can have more than one
    /// process able to receive on it. Every spawn makes one of those - the
    /// parent and the child are both given `.receive` on the endpoint between
    /// them - so "the receiver died" is not a question with an answer, while
    /// "there is no receiver left" is.
    ///
    /// Zero means nobody can ever take a message from here again, which is what
    /// turns a blocking send from waiting into waiting forever. `RendezvousIPC`
    /// maintains this in `retain` and `release`, beside `references`.
    ///
    /// `UInt16` because it lands in padding the struct already had, so an
    /// endpoint is the same 24 bytes it was. It counts capabilities, and the
    /// system cannot hold more than a process table's worth of those.
    public var receivers : UInt16        = 0     // 2 Byte

    /// The interrupt set bound to this endpoint, if one is.
    ///
    /// Here rather than only on the set, so that a `receive` about to park can
    /// ask "has my device said anything?" with one pointer load instead of a
    /// walk of the receiver's capability table. It is the set that owns the
    /// relationship: binding takes a reference on this endpoint, and the set's
    /// release clears this field, so it is never read after the set is gone.
    public var signals: UnsafeMutablePointer<InterruptSet>? = nil // 8 Byte

    public init(queue: LinkedList<Process>) {
        self.queue = queue
    }
}
