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

    /// Raw `x6`, identity in the high word, session in the low one
    public var badgeWord    : UInt64 = 0
    
    public var grantedHandle: UInt64 = 0
}
