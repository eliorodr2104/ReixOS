//
//  RXIPCShared.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//
//  Shared IPC data structures.
//


public struct MessageTag {
    public var label : UInt32 // 4 Byte
    public var length: UInt8  // 1 Byte

    public init(
        _ label : some IPCLabel,
        length  : UInt8
    ) {
        self.label  = label.rawValue
        self.length = length
    }

    public func packed() -> UInt64 {
        return (UInt64(label) << 8) | UInt64(length)
    }

    public init(packed raw: UInt64) {
        self.label  = UInt32((raw >> 8) & 0xFFFF_FFFF)
        self.length = UInt8(raw & 0xFF)
    }
}


public struct Message {

    public var words: InlineArray<4, UInt32> // 16 Byte
    public var tag  : MessageTag             // 5 Byte
        

    public init(
        tag  : MessageTag,
        words: InlineArray<4, UInt32>
    ) {
        self.tag   = tag
        self.words = words
    }
}


public enum IPCStatus: UInt64 {
    case ok = 0
    case wouldBlock
    case notEnoughRights
    case invalidCapability
    case timeout
    case noReply
    case invalidMessage
    case outOfEndpoints
}



public protocol IPCLabel: RawRepresentable where RawValue == UInt32 {  }
