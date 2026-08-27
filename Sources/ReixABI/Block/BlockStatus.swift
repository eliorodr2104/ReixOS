//
//  BlockStatus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// How a block request ended.
///
/// A named case rather than a number, and a number rather than a bitmask: the
/// caller writes `case .outOfRange` and not `if err & 0x2`. Which one came back
/// is also the only diagnosis available on the client side, so each one says
/// something the others do not.
public enum BlockStatus: UInt32 {

    case ok = 0

    /// The sectors asked for are not all on the device.
    case outOfRange

    /// More sectors than the shared window can hold in one go. Not the same
    /// refusal as `outOfRange`: the sectors exist, the room does not.
    case tooLong

    /// The caller never handed the server a window to move bytes through.
    case notAttached

    /// The device took the request and failed it.
    case deviceRefused

    /// Every one of the server's slots is out with the device, so this request
    /// was not started. Ask again.
    ///
    /// Backpressure, and the one refusal here that means "later" rather than
    /// "no". It could not happen while a server served one request at a time,
    /// because there was no moment at which it was holding any: it is the price
    /// of a queue, and the alternative - a queue of its own behind the device's -
    /// is two queues and a client that cannot tell how long either is.
    case queueFull

    /// The request never got an answer. Only a client can see this one: it means
    /// the IPC itself went wrong, not the disk.
    case unreachable

    /// Somebody else is holding the volume, so this request is not one the
    /// server may serve while that lasts. What a mount refusal looks like, and
    /// what a read-only view is told while a file system is mounted.
    case volumeHeld

    /// The caller does not hold the volume. Every write says this until one
    /// process has claimed the disk, which is the whole of the rule: a sector
    /// changes only for whoever holds the thing the sector is part of.
    case notMounted

    /// The capability used may look and not touch. Not the same refusal as
    /// `notMounted`: that one is about timing, this one about the handle, and no
    /// amount of waiting turns one into the other.
    case readOnly

    /// The capability used does not carry that authority at all. What a request
    /// refused this way needs is a different handle, not a different moment and
    /// not a narrower request.
    case notAuthorised

    /// The device cannot say what a completed write has achieved, so this
    /// request is one nothing on it can be built on.
    ///
    /// The answer to a `flush` on a device that never negotiated a way to empty
    /// a cache. It used to be `ok`, and that was the whole bug: a barrier that
    /// answers `ok` because there is nothing to ask is indistinguishable from a
    /// barrier that answers `ok` because nobody knows what to ask, and the
    /// second one is a file system's ordering rule turned into a wish.
    ///
    /// Not a refusal that waiting or a narrower request changes. It is a fact
    /// about the device, so it is the same answer every time until the device is
    /// a different device.
    case durabilityUnknown

    /// A request under a name that already has an answer coming.
    ///
    /// A tag is how a client names a transfer it will collect later, and the
    /// server holds one cell per name for the answer to go in. A second request
    /// under the same name has nowhere for its answer to be filed, so it is
    /// refused before the device is told anything.
    ///
    /// This is also the whole of the local throttle. A client that stops
    /// collecting fills its own names and then meets this on everything it asks
    /// for, which costs the disk nothing and costs every other client nothing.
    /// Distinct from `queueFull`, which is the shared queue being busy and is
    /// answered by asking again: this one is answered by collecting.
    case duplicateTag
}
