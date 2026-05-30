//
//  Message.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct Message {
    public var tag: MessageTag
    public var words: InlineArray<8, UInt32>
    
    // Payload with Shared Mem
    // public var buffer: BufferRef  // (capacity + handle to shared mem)

    public init(
        tag  : MessageTag,
        words: InlineArray<8, UInt32>
    ) {
        self.tag   = tag
        self.words = words
    }
}
