//
//  RXIPC.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

private struct ReceivedMessageRaw {
    public var tag          : UInt64 = 0
    public var word0        : UInt64 = 0
    public var word1        : UInt64 = 0
    public var word2        : UInt64 = 0
    public var word3        : UInt64 = 0
    public var badge        : UInt64 = 0
    public var grantedHandle: UInt64 = 0
}

public struct ReceivedMessage {
    public var message   : Message
    public var grantedCap: UInt32?
    public var badge     : UInt32
    
    init(
        message   : Message,
        grantedCap: UInt32,
        badge     : UInt32
    ) {
        self.message    = message
        self.grantedCap = grantedCap == UInt32.max ? nil : UInt32(grantedCap)
        self.badge      = badge
    }
}


@inline(__always)
public func send(
    handle     : UInt32,
    message    : Message,
    grant      : UInt32?    = nil,
    grantRights: CapRights  = [.send, .receive]
) -> IPCStatus {
    
    let grantHandle = grant ?? UInt32.max
    let grantWord   = (UInt64(grantRights.rawValue) << 32) | UInt64(grantHandle)

     return IPCStatus(
        rawValue: _syscall(
            .send,
            UInt64(handle),
            message.tag.packed(),
            UInt64(message.words[0]),
            UInt64(message.words[1]),
            UInt64(message.words[2]),
            UInt64(message.words[3]),
            grantWord
        )
     ) ?? .invalidMessage
}


@inline(__always)
public func receive(handle: UInt32) -> ReceivedMessage {
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

    return ReceivedMessage(
        message   : Message(tag: MessageTag(packed: raw.tag), words: w),
        grantedCap: UInt32(raw.grantedHandle),
        badge     : UInt32(raw.badge)
    )
}


@inline(__always)
public func receive(
    handle : UInt32,
    timeout: UInt32
) -> ReceivedMessage? {
    var raw = ReceivedMessageRaw()

    let resultAsm = withUnsafeMutablePointer(to: &raw) { ptr in
        _asm_recv_timeout_raw(
            SyscallNumber.receiveTimeout.rawValue,
            UInt64(handle),
            UInt64(timeout),
            UnsafeMutableRawPointer(ptr)
        )
    }

    guard resultAsm == IPCStatus.ok.rawValue else { return nil }

    var w = InlineArray<4, UInt32>(repeating: 0)
    w[0] = UInt32(truncatingIfNeeded: raw.word0)
    w[1] = UInt32(truncatingIfNeeded: raw.word1)
    w[2] = UInt32(truncatingIfNeeded: raw.word2)
    w[3] = UInt32(truncatingIfNeeded: raw.word3)

    return ReceivedMessage(
        message   : Message(tag: MessageTag(packed: raw.tag), words: w),
        grantedCap: UInt32(raw.grantedHandle),
        badge     : UInt32(raw.badge)
    )
}


@inline(__always)
public func spawnEndpoint() -> UInt32 {
    return UInt32(truncatingIfNeeded: _syscall(.spawnEndpoint))
}


@inline(__always)
public func call(
    handle : UInt32,
    message: Message
) -> ReceivedMessage {
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

    return ReceivedMessage(
        message   : Message(tag: MessageTag(packed: raw.tag), words: w),
        grantedCap: UInt32(raw.grantedHandle),
        badge     : UInt32(raw.badge)
    )
}


@inline(__always)
public func reply(
    message    : Message,
    grant      : UInt32?   = nil,
    grantRights: CapRights = [.send]
) -> IPCStatus {
    
    let grantHandle = grant ?? UInt32.max
    let grantWord   = (UInt64(grantRights.rawValue) << 32) | UInt64(grantHandle)
    
    return IPCStatus(
        rawValue: _syscall(
            .reply,
            0,
            message.tag.packed(),
            UInt64(message.words[0]),
            UInt64(message.words[1]),
            UInt64(message.words[2]),
            UInt64(message.words[3]),
            grantWord
        )
    ) ?? .invalidMessage
}

@inline(__always)
public func replyRecv(
    handle : UInt32,
    message: Message
) -> ReceivedMessage {
    var raw = ReceivedMessageRaw()

    _ = withUnsafeMutablePointer(to: &raw) { ptr in
        _asm_call_raw(
            SyscallNumber.replyRecv.rawValue,
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

    return ReceivedMessage(
        message   : Message(tag: MessageTag(packed: raw.tag), words: w),
        grantedCap: UInt32(raw.grantedHandle),
        badge     : UInt32(raw.badge)
    )
}


@inline(__always)
public func trySend(
    handle : UInt32,
    message: Message,
    grant  : UInt32? = nil
) -> IPCStatus {
     IPCStatus(
        rawValue: _syscall(
            .trySend,
            UInt64(handle),
            message.tag.packed(),
            UInt64(message.words[0]),
            UInt64(message.words[1]),
            UInt64(message.words[2]),
            UInt64(message.words[3]),
            UInt64(grant ?? UInt32.max)
        )
     ) ?? .invalidMessage
}


@inline(__always)
public func tryReceive(handle: UInt32) -> ReceivedMessage? {
    var raw = ReceivedMessageRaw()

    let resultAsm = withUnsafeMutablePointer(to: &raw) { ptr in
        _asm_recv_raw(
            SyscallNumber.tryReceive.rawValue,
            UInt64(handle),
            UnsafeMutableRawPointer(ptr)
        )
    }
    
    
    guard resultAsm != 2 else { return nil }
    

    var w = InlineArray<4, UInt32>(repeating: 0)
    w[0] = UInt32(truncatingIfNeeded: raw.word0)
    w[1] = UInt32(truncatingIfNeeded: raw.word1)
    w[2] = UInt32(truncatingIfNeeded: raw.word2)
    w[3] = UInt32(truncatingIfNeeded: raw.word3)

    return ReceivedMessage(
        message   : Message(tag: MessageTag(packed: raw.tag), words: w),
        grantedCap: UInt32(raw.grantedHandle),
        badge     : UInt32(raw.badge)
    )
    
}


@inline(__always)
public func spawnService() -> UInt32? {
    let handle = UInt32(truncatingIfNeeded: _syscall(.spawnService))

    return handle == UInt32.max ? nil : handle
}


@inline(__always)
public func derive(
    handle: UInt32,
    badge : UInt32,
    rights: CapRights
) -> UInt32? {
    let result = UInt32(truncatingIfNeeded: _syscall(
        .derive,
        UInt64(handle),
        UInt64(badge),
        UInt64(rights.rawValue),
        0, 0, 0, 0
    ))

    return result == UInt32.max ? nil : result
}
