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


/// Wait for a message on `handle`.
///
/// A receive that failed comes back with a `status` that says so and a message
/// nobody sent, rather than with whatever the frame happened to hold: see
/// `ReceivedMessage.arrived`.
@inline(__always)
public func receive(handle: UInt32) -> ReceivedMessage {
    var raw = ReceivedMessageRaw()

    let outcome = withUnsafeMutablePointer(to: &raw) { ptr in
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
        message      : Message(tag: raw.tag.packed, words: w),
        sessionWord  : raw.sessionWord,
        principalWord: raw.principalWord,
        status       : IPCStatus(rawValue: outcome) ?? .invalidMessage
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
        message      : Message(tag: raw.tag.packed, words: w),
        sessionWord  : raw.sessionWord,
        principalWord: raw.principalWord,
        status       : .ok
    )
}


@inline(__always)
public func spawnEndpoint() -> UInt32 {
    return UInt32(truncatingIfNeeded: _syscall(.spawnEndpoint))
}


/// Send `message` on `handle` and wait for the reply.
///
/// Two kinds of fact come back from a call and they are not the same kind. What
/// a server *said* is a status inside the message. Whether there is a message at
/// all is the transport's answer, and the kernel leaves it in the caller's
/// frame: `.ok` for a reply that came, `.peerDied` when the server died holding
/// the request, `.noReply` when it dropped it, and a refusal of its own when the
/// capability could not be used.
///
/// They come back on separate channels here, which is the whole point of the
/// `Result`. The assembly copies `x1` through `x7` into the reply buffer
/// whatever happened, so on a failed call those words are the *request* looking
/// like an answer - and `ok` is zero in every status enum this system has, so
/// the most likely reading of a failure was success.
///
/// A caller cannot get at the message without saying what it will do about the
/// exchange not having happened. That is not politeness; it is the only way this
/// is checkable at compile time rather than remembered at thirty call sites.
@inline(__always)
public func call(
    handle : UInt32,
    message: Message
) -> Result<ReceivedMessage, IPCStatus> {
    
    var raw = ReceivedMessageRaw()

    let outcome = withUnsafeMutablePointer(to: &raw) { ptr in
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

    let status = IPCStatus(rawValue: outcome) ?? .invalidMessage

    // `grantRejected` is a delivered reply whose capability did not travel, so
    // the words are real and only the grant is missing.
    guard status.isDelivered else { return .failure(status) }

    var w = InlineArray<4, UInt32>(repeating: 0)
    w[0] = UInt32(truncatingIfNeeded: raw.word0)
    w[1] = UInt32(truncatingIfNeeded: raw.word1)
    w[2] = UInt32(truncatingIfNeeded: raw.word2)
    w[3] = UInt32(truncatingIfNeeded: raw.word3)

    return .success(ReceivedMessage(
        message      : Message(tag: raw.tag.packed, words: w),
        sessionWord  : raw.sessionWord,
        principalWord: raw.principalWord,
        status       : status
    ))
}


/// Answers a caller.
///
/// `to` names which one, for a server holding more than one request at a time,
/// and it is the `identity` the request arrived with. Left out, the answer goes
/// to the newest caller, which is the only one a server that answers every
/// request before taking the next one ever has.
///
/// A named caller that is not waiting on this process is refused with `noReply`
/// rather than being quietly redirected to whoever is newest: delivering a reply
/// to the wrong client is worse than not delivering it.
@inline(__always)
public func reply(
    message    : Message,
    grant      : UInt32?   = nil,
    grantRights: CapRights = [.send],
    to identity: UInt32    = 0
) -> IPCStatus {
    
    let grantHandle = grant ?? UInt32.max
    let grantWord   = (UInt64(grantRights.rawValue) << 32) | UInt64(grantHandle)
    
    return IPCStatus(
        rawValue: _syscall(
            .reply,
            UInt64(identity),
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
        message      : Message(tag: raw.tag.packed, words: w),
        sessionWord  : raw.sessionWord,
        principalWord: raw.principalWord
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
        message      : Message(tag: raw.tag.packed, words: w),
        sessionWord  : raw.sessionWord,
        principalWord: raw.principalWord
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
///
/// Sixty-four bits of it, and the file system is why: a badge that says which
/// object, which incarnation of it, and what its holder may do wants more than a
/// word between the three. See `FSBadge`.
/// Returns `nil` when the source lacks `.derive`.
@inline(__always)
public func derive(
    handle : UInt32,
    session: UInt64,
    rights : CapRights
) -> UInt32? {
    
    let result = UInt32(truncatingIfNeeded: _syscall(
        .derive,
        UInt64(handle),
        session,
        UInt64(rights.rawValue),
        0, 0, 0, 0
    ))

    return result == UInt32.max ? nil : result
}


/// How many pages the shared region `handle` names really holds.
///
/// `0` when the handle is not a shared region. A server maps a window a client
/// granted and has, until it asks this, only the client's word for how far that
/// window reaches - and a window described as bigger than it is, is a server
/// writing off the end of it.
@inline(__always)
public func shmPages(handle: UInt32) -> UInt32 {
    UInt32(truncatingIfNeeded: _syscall(.shmPages, UInt64(handle)))
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

/// Asks for this interrupt set to knock on `endpoint` when a line fires.
///
/// After this, one `receive` on that endpoint answers a client or the device,
/// whichever speaks first, and a driver no longer has to choose which of the two
/// to wait for. A notification is recognised by `InterruptNotification.names`.
///
/// Nothing is queued: the event lives in the set exactly as it did before, so a
/// line that fires while nobody is receiving is collected by the next `receive`
/// without blocking. `irqAck` is unchanged and still required.
///
/// `false` when the handle names no interrupt set, or when the endpoint is not
/// one this process may receive on - being woken somewhere you never wait is not
/// a thing to allow by accident.
@inline(__always)
public func irqBind(
    handle  : UInt32,
    endpoint: UInt32

) -> Bool { _syscall(.irqBind, UInt64(handle), UInt64(endpoint)) == 0 }


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
/// Waits for one of the lines `handle` names to fire.
///
/// `ticks` of zero waits for as long as it takes. Anything else is a deadline,
/// and `0` comes back when it passes - which no real answer can be, because a
/// wake with no line set does not happen.
///
/// A driver that waits without one is a driver that a wedged device parks for
/// the rest of the boot, and everything above it with it.
@inline(__always)
public func irqWait(
    handle: UInt32,
    ticks : UInt64 = 0

) -> UInt64 { _syscall(.irqWait, UInt64(handle), ticks) }


/// Unmasks the lines named by `bits`, after their device has been serviced.
///
/// Bits for lines this holder does not have masked are ignored rather than
/// arming a line nobody is ready for. Answers `0`, or `UInt64.max` when the
/// handle is not an interrupt set.
public func irqAck(
    handle: UInt32,
    bits  : UInt64
    
) -> UInt64 { _syscall(.irqAck, UInt64(handle), bits) }


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
public func deviceRead(
    handle: UInt32,
    offset: UInt64

) -> UInt64 { _syscall(.deviceRead, UInt64(handle), offset) }


/// Writes one 32-bit register at `offset`. Answers `0`, or `UInt64.max` on the
/// same refusals as `deviceRead` with `write` in place of `read`.
@inline(__always)
public func deviceWrite(
    handle: UInt32,
    offset: UInt64,
    value : UInt32

) -> UInt64 { _syscall(.deviceWrite, UInt64(handle), offset, UInt64(value)) }


// MARK: - Buses

/// Carves the `index`th transport's window out of a bus and answers a device
/// capability for it.
///
/// An index, not an address: the window is the one the machine's own description
/// declared, whole, so there is no way to ask for the space between two of them.
/// A transport that is an eighth of a page stays an eighth of a page and is
/// reached with `deviceRead` rather than mapped. Rights are whatever the bus
/// carried, never more.
///
/// `UInt32.max` when the handle names no bus, the bus does not carry `derive`,
/// or the bus has no such transport, which is how a walk learns where to stop.
@inline(__always)
public func busDeriveDevice(
    handle: UInt32,
    index : UInt32

) -> UInt32 {
    UInt32(truncatingIfNeeded: _syscall(.busDeriveDevice, UInt64(handle), UInt64(index)))
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
public func busDeriveInterrupt(
    handle: UInt32,
    index : UInt32

) -> UInt32 {
    UInt32(truncatingIfNeeded: _syscall(.busDeriveInterrupt, UInt64(handle), UInt64(index)))
}
