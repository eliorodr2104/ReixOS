//
//  RXIPC.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

private struct ReceivedMessageRaw {
    public var tag  : UInt64 = 0
    public var word0: UInt64 = 0
    public var word1: UInt64 = 0
    public var word2: UInt64 = 0
    public var word3: UInt64 = 0
    public var badge: UInt64 = 0
}


@inline(__always)
public func send(
    handle : UInt32,
    message: Message
) -> UInt64 {
     _syscall(
        .send,
        UInt64(handle),
        message.tag.packed(),
        UInt64(message.words[0]),
        UInt64(message.words[1]),
        UInt64(message.words[2]),
        UInt64(message.words[3])
    )
}


@inline(__always)
public func receive(handle: UInt32) -> Message {
    var raw = ReceivedMessageRaw()

    _ = withUnsafeMutablePointer(to: &raw) { ptr in
        _asm_recv_raw(
            SyscallNumber.receive.rawValue,
            UInt64(handle),
            UnsafeMutableRawPointer(ptr)
        )
    }

    var w = InlineArray<4, UInt32>(repeating: 0)
    w[0] = UInt32(truncatingIfNeeded: raw.word0)
    w[1] = UInt32(truncatingIfNeeded: raw.word1)
    w[2] = UInt32(truncatingIfNeeded: raw.word2)
    w[3] = UInt32(truncatingIfNeeded: raw.word3)

    return Message(tag: MessageTag(packed: raw.tag), words: w)
}


@inline(__always)
public func spawnEndpoint() -> UInt32 {
    return UInt32(truncatingIfNeeded: _syscall(.spawnEndpoint))
}


@inline(__always)
public func call(
    handle : UInt32,
    message: Message
) -> Message {
    var raw = ReceivedMessageRaw()

    _ = withUnsafeMutablePointer(to: &raw) { ptr in
        _asm_call_raw(
            SyscallNumber.call.rawValue,
            UInt64(handle),
            message.tag.packed(),
            UInt64(message.words[0]),
            UInt64(message.words[1]),
            UInt64(message.words[2]),
            UInt64(message.words[3]),
            UnsafeMutableRawPointer(ptr)
        )
    }

    var w = InlineArray<4, UInt32>(repeating: 0)
    w[0] = UInt32(truncatingIfNeeded: raw.word0)
    w[1] = UInt32(truncatingIfNeeded: raw.word1)
    w[2] = UInt32(truncatingIfNeeded: raw.word2)
    w[3] = UInt32(truncatingIfNeeded: raw.word3)

    return Message(tag: MessageTag(packed: raw.tag), words: w)
}


@inline(__always)
public func reply(message: Message) -> UInt64 {
    return _syscall(
        .reply,
        0,
        message.tag.packed(),
        UInt64(message.words[0]),
        UInt64(message.words[1]),
        UInt64(message.words[2]),
        UInt64(message.words[3])
    )
}
