//
//  RXIPCShared.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//
//  Shared IPC data structures.
//


public struct MessageTag {
    public var label : UInt32
    public var length: UInt8

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

    public var tag  : MessageTag
    public var words: InlineArray<4, UInt32>

    public init(
        tag  : MessageTag,
        words: InlineArray<4, UInt32>
    ) {
        self.tag   = tag
        self.words = words
    }
}


public protocol IPCLabel: RawRepresentable where RawValue == UInt32 {  }
