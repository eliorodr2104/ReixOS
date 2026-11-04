//
//  Message.swift
//  ReixOS
//
//  Shared IPC type (compiled into BOTH kernel and Reix module).
//

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
