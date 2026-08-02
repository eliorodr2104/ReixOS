//
//  RXIPC.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

import ReixABI

/// Send `message` on `handle`, blocking until somebody receives it.
///
/// `.grantRejected` means the message landed but `grant` did not: the receiver
/// read no capability. It is an outcome of a *successful* send, so resending
/// would duplicate the message; re-offer the capability instead, or use
/// `IPCStatus.isDelivered` when only delivery matters.
///
/// Only a send that had to wait for a receiver can report it today. When a
/// receiver was already parked on the endpoint the kernel still answers `.ok`
/// even if it dropped the grant, so a caller that must be certain has to check
/// the capability arrived by other means.
@discardableResult
@inline(__always)
public func send(
    handle     : UInt32,
    message    : Message,
    grant      : UInt32?   = nil,
    grantRights: CapRights = [.send, .receive]
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
        message   : Message(tag: raw.tag.packed, words: w),
        grantedCap: UInt32(truncatingIfNeeded: raw.grantedHandle),
        badgeWord : raw.badgeWord
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
        message   : Message(tag: raw.tag.packed, words: w),
        grantedCap: UInt32(truncatingIfNeeded: raw.grantedHandle),
        badgeWord : raw.badgeWord
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
        message   : Message(tag: raw.tag.packed, words: w),
        grantedCap: UInt32(truncatingIfNeeded: raw.grantedHandle),
        badgeWord : raw.badgeWord
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
        message   : Message(tag: raw.tag.packed, words: w),
        grantedCap: UInt32(truncatingIfNeeded: raw.grantedHandle),
        badgeWord : raw.badgeWord
    )
}


@inline(__always)
public func trySend(
    handle     : UInt32,
    message    : Message,
    grant      : UInt32?   = nil,
    grantRights: CapRights = [.send, .receive]
) -> IPCStatus {

    let grantHandle = grant ?? UInt32.max
    let grantWord   = (UInt64(grantRights.rawValue) << 32) | UInt64(grantHandle)

    return IPCStatus(
        rawValue: _syscall(
            .trySend,
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
public func tryReceive(handle: UInt32) -> ReceivedMessage? {
    var raw = ReceivedMessageRaw()

    let resultAsm = withUnsafeMutablePointer(to: &raw) { ptr in
        _asm_recv_raw(
            SyscallNumber.tryReceive.rawValue,
            UInt64(handle),
            UnsafeMutableRawPointer(ptr)
        )
    }
    
    
    guard resultAsm != IPCStatus.wouldBlock.rawValue else { return nil }
    

    var w = InlineArray<4, UInt32>(repeating: 0)
    w[0] = UInt32(truncatingIfNeeded: raw.word0)
    w[1] = UInt32(truncatingIfNeeded: raw.word1)
    w[2] = UInt32(truncatingIfNeeded: raw.word2)
    w[3] = UInt32(truncatingIfNeeded: raw.word3)

    return ReceivedMessage(
        message   : Message(tag: raw.tag.packed, words: w),
        grantedCap: UInt32(truncatingIfNeeded: raw.grantedHandle),
        badgeWord : raw.badgeWord
    )
    
}


@inline(__always)
public func spawnService() -> UInt32? {
    let handle = UInt32(truncatingIfNeeded: _syscall(.spawnService))

    return handle == UInt32.max ? nil : handle
}


/// Bind an unbadged capability to `session`, as a new reduced-rights handle.
///
/// Only the session is caller-chosen, identity is stamped by the kernel from the
/// sending process, so this cannot be used to speak as another principal.
/// Returns `nil` when the source lacks `.derive`.
@inline(__always)
public func derive(
    handle : UInt32,
    session: UInt32,
    rights : CapRights
) -> UInt32? {
    
    let result = UInt32(truncatingIfNeeded: _syscall(
        .derive,
        UInt64(handle),
        UInt64(session),
        UInt64(rights.rawValue),
        0, 0, 0, 0
    ))

    return result == UInt32.max ? nil : result
}


@inline(__always)
public func deviceCap() -> UInt32? {
    let parentDeviceHandle = UInt32(truncatingIfNeeded: _syscall(.deviceCap))
    return parentDeviceHandle == UInt32.max ? nil : parentDeviceHandle
}

@inline(__always)
public func mapDevice(handle: UInt32) -> UInt64 {
    _syscall(.mapDevice, UInt64(handle))
}

@inline(__always)
public func capExists(_ handle: UInt32) -> Bool {
    _syscall(.capExists, UInt64(handle)) != 0
}


/// Give the capability at `handle` back to the kernel and free its table slot.
///
/// **Unmap before you drop.** Anything mapped through this capability
/// (`shmMap`, `mapDevice`) must be unmapped *first*. This is the last reference
/// counted against the target, so for a shared region the drop can free its
/// physical frames; a mapping left behind then points at memory the kernel is
/// free to hand to somebody else, and writing through it corrupts whatever lands
/// there.
///
/// Returns `true` when the capability was dropped, `false` when this process
/// holds nothing at `handle`.
@inline(__always)
public func capDrop(_ handle: UInt32) -> Bool {
    _syscall(.capDrop, UInt64(handle)) == 0
}
