//
//  MessageTag.swift
//  ReixOS
//
//  Shared IPC type (compiled into BOTH kernel and Reix module).
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
