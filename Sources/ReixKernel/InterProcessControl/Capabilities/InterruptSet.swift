//
//  InterruptSet.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// The authority to receive one group of interrupt lines, and the state of
/// their delivery.
///
/// A capability target rather than a message on an endpoint, for a structural
/// reason: `Endpoint.queue` holds *processes waiting*, not messages, so a
/// rendezvous has nowhere to leave an event when nobody is receiving, and an
/// interrupt handler is the one context that must never block waiting for a
/// receiver. This object is that missing place, and it is one word wide.
///
/// Signalling the same line twice before its holder looks sets the same bit
/// twice, which is one wakeup. That is not a loss: a driver re-reads its
/// device's status register anyway, so an edge count was never the thing worth
/// preserving.
///
/// Reference counted like `Endpoint` and `SharedRegion`, and for the payoff
/// that comes with it: `releaseCapabilities` already walks a dying process's
/// table, so a driver that crashes holding a masked line drops the last
/// reference and the release path gives every line back. Without the refcount
/// that crash would silence a device until reboot.
public struct InterruptSet: RXObject {

    public static var errorMessageAllocation: StaticString = "Failed to allocate an interrupt set on the kernel heap"

    /// The most lines one holder may group.
    ///
    /// Eight because `pending` and `masked` are one byte each and one driver
    /// owning more than eight lines is not a machine this kernel runs on yet.
    /// Raising it means widening both words; nothing else reads the bound.
    public static let maxLines = 8

    /// The lines, in the order the bits of `pending` and `masked` name them:
    /// bit `i` is `lines[i]`. Only the first `lineCount` are meaningful.
    public var lines    : InlineArray<8, UInt32>
    public var lineCount: UInt8

    /// Lines that fired and have not been collected by a waiter yet.
    public var pending: UInt8

    /// Lines the kernel masked on delivery and is waiting for an ack on.
    ///
    /// Tracked rather than inferred from `pending`, because the two come apart:
    /// a waiter collects the pending bit as soon as it wakes, and the line stays
    /// masked until the driver has actually serviced the device and acked.
    public var masked: UInt8

    /// The process parked in `irqWait`, if any. One, not a queue: the holder of
    /// this authority is a driver, and two threads waiting on the same set would
    /// be racing for the same device registers anyway.
    public var waiter: UnsafeMutablePointer<Process>?

    /// The endpoint to wake when a line fires, if the holder asked for one.
    ///
    /// The alternative to `irqWait`, and the reason a driver can now wait for a
    /// request and for its device in the same place. Nothing is queued here: the
    /// event stays in `pending`, exactly as before, and this only says where to
    /// go looking for somebody to tell.
    ///
    /// The set holds a reference on it, one way round on purpose: a bound
    /// endpoint cannot be freed while the set that names it is alive, so the
    /// back pointer on the endpoint is only ever read while the set exists.
    public var notify: UnsafeMutablePointer<Endpoint>?

    public var references: UInt32


    public init() {
        self.lines      = InlineArray<8, UInt32>(repeating: 0)
        self.lineCount  = 0
        self.pending    = 0
        self.masked     = 0
        self.waiter     = nil
        self.notify     = nil
        self.references = 0
    }


    /// Adds `line` to the set, answering the bit it was given, or `nil` when
    /// the set is full or already covers it.
    public mutating func add(line: UInt32) -> UInt8? {
        guard lineCount < UInt8(Self.maxLines) else { return nil }

        for index in 0..<Int(lineCount) where lines[index] == line {
            return nil
        }

        let bit = UInt8(1) << lineCount
        lines[Int(lineCount)] = line
        lineCount &+= 1

        return bit
    }


    /// The bit naming `line`, or `nil` when this set does not cover it.
    public func bit(of line: UInt32) -> UInt8? {
        for index in 0..<Int(lineCount) where lines[index] == line {
            return UInt8(1) << UInt8(index)
        }

        return nil
    }
}
