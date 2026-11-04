//
//  IPCDelivery.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// The two registers a delivered message carries besides its words, packed the
/// one way.
///
/// Three facts travel out of band: which conversation the message belongs to,
/// who sent it, and which capability came with it. They used to share two halves
/// of one register - identity above, session below - and that sharing put a
/// thirty-two bit ceiling on a session. A session is a token a server hands out
/// and later has to tell apart from every other token it has ever handed out, so
/// a ceiling on it is a ceiling on how long it can be before two of them are the
/// same number.
///
/// So the session has a register of its own and the other two share the second:
///
/// ```
/// x6 = session, all sixty-four bits
/// x7 = sender identity in the high word, granted capability in the low one
/// ```
///
/// An identity is a process counter and a handle is an index into a table of
/// thirty-two, so neither wants more than a word. The session does.
///
/// These are the registers on the way *out*, to a receiver. On the way in, `x6`
/// is the sender's own argument: a handle to hand over with the rights to hand it
/// with. Two meanings for one register in one syscall, and they never meet -
/// one is read out of the sender's frame and the other written into the
/// receiver's.
///
/// **One place, and every path through it.** Immediate send, queued send,
/// receive, call, reply, timeout and a grant that was refused all pack their two
/// registers here. They used to each build the word themselves, which is six
/// chances to shift by the wrong amount and one of them being a path nothing
/// tests.
public enum IPCDelivery {

    /// What the granted-capability half holds when nothing came with the message.
    ///
    /// Not zero: zero is handle zero, which is a real slot. A reader that treated
    /// it as "nothing" would be told to drop somebody's console.
    public static let noGrant: UInt32 = UInt32.max

    /// The second register: who sent it, and what came with it.
    public static func principal(
        _ identity: UInt32,
        grant     : UInt32 = noGrant
    ) -> UInt64 {
        (UInt64(identity) << 32) | UInt64(grant)
    }

    /// The identity out of a packed second register.
    public static func identity(of principal: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: principal >> 32)
    }

    /// The granted handle out of a packed second register, or nil when nothing
    /// came with the message.
    public static func grant(of principal: UInt64) -> UInt32? {
        let handle = UInt32(truncatingIfNeeded: principal)
        return handle == noGrant ? nil : handle
    }
}
