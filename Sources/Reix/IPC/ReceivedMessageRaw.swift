//
//  ReceivedMessageRaw.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//

public struct ReceivedMessageRaw {
    public var tag          : UInt64 = 0
    public var word0        : UInt64 = 0
    public var word1        : UInt64 = 0
    public var word2        : UInt64 = 0
    public var word3        : UInt64 = 0

    /// Raw `x6`: the session, all sixty-four bits of it.
    ///
    /// It used to be a register shared with the sender's identity, which put a
    /// ceiling on how wide a session could be. See `IPCDelivery`.
    public var sessionWord  : UInt64 = 0

    /// Raw `x7`: the sender's identity above, the granted capability below.
    public var principalWord: UInt64 = 0
}
