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


// MARK: - Interrupts

/// Blocks until one of the lines `handle` names fires, and answers which.
///
/// The answer is a bit per line, in the order the set was built, so a holder of
/// several lines learns in one wake-up which of them need servicing. Lines that
/// fired while nobody was waiting are not lost: the first call collects them
/// without blocking.
///
/// Every line in the answer is *masked* when this returns. The device will not
/// interrupt again on it until `irqAck` is called, which is what stops a device
/// that holds its line up from re-entering the handler forever. Service the
/// device first, acknowledge second.
///
/// `UInt64.max` means the handle is not an interrupt set, or somebody is
/// already waiting on it.
public func irqWait(handle: UInt32) -> UInt64 {
    _syscall(.irqWait, UInt64(handle))
}


/// Unmasks the lines named by `bits`, after their device has been serviced.
///
/// Bits for lines this holder does not have masked are ignored rather than
/// arming a line nobody is ready for. Answers `0`, or `UInt64.max` when the
/// handle is not an interrupt set.
public func irqAck(
    handle: UInt32,
    bits  : UInt64
    
) -> UInt64 {
    _syscall(.irqAck, UInt64(handle), bits)
}


// MARK: - Device registers

/// Reads one 32-bit register at `offset` inside the window `handle` names.
///
/// For a device window too small to map: the smallest thing the memory unit can
/// hand over is a 4 KiB page, and a 512-byte window shares its page with seven
/// other devices, so a window that size is reached one access at a time with
/// the kernel checking the bound instead.
///
/// Answers the register zero-extended, or `UInt64.max` when the handle names no
/// device, the capability does not carry `read`, or the offset falls outside.
@inline(__always)
public func deviceRead(handle: UInt32, offset: UInt64) -> UInt64 {
    _syscall(.deviceRead, UInt64(handle), offset)
}


/// Writes one 32-bit register at `offset`. Answers `0`, or `UInt64.max` on the
/// same refusals as `deviceRead` with `write` in place of `read`.
@inline(__always)
public func deviceWrite(handle: UInt32, offset: UInt64, value: UInt32) -> UInt64 {
    _syscall(.deviceWrite, UInt64(handle), offset, UInt64(value))
}


// MARK: - Buses

/// Carves the window `[offset, offset + size)` out of a bus and answers a
/// device capability for it.
///
/// The window comes back exactly the size asked for, so a transport that is an
/// eighth of a page stays an eighth of a page and is reached with `deviceRead`
/// rather than mapped. Rights are whatever the bus carried, never more.
///
/// `UInt32.max` when the handle names no bus, the bus does not carry `derive`,
/// or the window falls outside it.
@inline(__always)
public func busDeriveDevice(handle: UInt32, offset: UInt64, size: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: _syscall(.busDeriveDevice, UInt64(handle), offset, size))
}


/// Carves the line of one transport out of a bus and answers a capability that
/// waits on it.
///
/// `index` counts transports from the base of the bus, the same way the window
/// offset does. No interrupt numbers appear here: which line the third slot
/// raises is the machine's business, and the kernel read it from the machine's
/// own description.
///
/// `UInt32.max` when the bus has no such transport, or when somebody already
/// holds that line: one line has one owner, and a bus is not an exception.
@inline(__always)
public func busDeriveInterrupt(handle: UInt32, index: UInt32) -> UInt32 {
    UInt32(truncatingIfNeeded: _syscall(.busDeriveInterrupt, UInt64(handle), UInt64(index)))
}
