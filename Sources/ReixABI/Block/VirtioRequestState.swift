//
//  VirtioRequestState.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// What a driver has out with a device, and every rule a completion has to
/// satisfy before a byte of it is believed.
///
/// All of the bookkeeping and none of the hardware, which is the point: a device
/// that answers with an id nobody sent, a length nobody asked for, or nothing at
/// all inside five seconds is a device this file can be shown on a host with no
/// disk in it. What was here before lived inside the driver as two arrays and
/// three checks spread over two methods, so the only way to ask "what does this
/// do when the ring says that" was to find a device that would say it.
///
/// `InlineArray` throughout. A driver allocates nothing, and the interrupt path
/// least of all.
public struct VirtioRequestState {

    /// Requests out at once, matching the queue the driver builds.
    public static let capacity = BlockQueue.depth

    /// What a status byte holds before the device has written it.
    ///
    /// Not a status virtio uses, which is the whole reason for the value: seeing
    /// it again means the device never wrote one, rather than having written
    /// success. A completion whose status byte still reads this is a completion
    /// the device did not finish making.
    public static let unwritten: UInt8 = 0xFF

    /// How long a request may be outstanding before the device is presumed gone.
    ///
    /// Far longer than any request this driver makes should take, and finite,
    /// which is the point. A wait with no end turns one stuck device into a stuck
    /// block server, and a stuck block server into a machine with no files.
    public static let patienceSeconds: UInt64 = 5


    /// What kind of request a slot is carrying.
    public enum Kind: UInt8, Equatable {
        case read, write, flush

        /// Whether the device writes the data descriptor. Only a read.
        public var deviceWrites: Bool { self == .read }
    }


    /// A way for a device to have said something impossible.
    ///
    /// Five, and they are five because they are five different lies. Naming them
    /// apart is what lets a test say which one it provoked, and what lets the
    /// console line say which one happened.
    public enum Fault: UInt8, Equatable {

        /// An id that is not the head of any chain this driver built.
        case unknownChain

        /// A slot that was not out with the device. Covers a completion arriving
        /// twice: the second one finds the slot already given back.
        case notOutstanding

        /// A used length that is not what a completion of that kind writes.
        case wrongLength

        /// The status byte still holds the value this driver put there, so the
        /// device moved the index without finishing the request.
        case statusNotWritten

        /// The used index moved further than there are requests to complete.
        case tooManyCompletions
    }


    public enum Verdict: Equatable {

        /// The completion is this slot's, and this many sectors of its data page
        /// are the device's answer. `failed` is the device's own status byte.
        case accept(slot: Int, sectors: UInt32, failed: Bool)

        case fault(Fault)
    }


    private var busy      = InlineArray<4, Bool>(repeating: false)
    private var kinds     = InlineArray<4, Kind>(repeating: .read)
    private var requested = InlineArray<4, UInt32>(repeating: 0)
    private var expected  = InlineArray<4, UInt64>(repeating: 0)
    private var deadlines = InlineArray<4, UInt64>(repeating: 0)

    /// The most requests that were ever out at once.
    ///
    /// A depth nobody can see fill up is a depth whose value is a guess. This is
    /// what makes the four a measurement.
    public private(set) var highWater = 0

    public init() {}


    // MARK: - What is out

    public var outstanding: Int {
        var many = 0
        for slot in 0..<Self.capacity where busy[slot] { many += 1 }
        return many
    }

    public var idle: Bool { outstanding == 0 }

    public func isBusy(_ slot: Int) -> Bool {
        guard slot >= 0, slot < Self.capacity else { return false }
        return busy[slot]
    }

    public func freeSlot() -> Int? {
        for slot in 0..<Self.capacity where !busy[slot] { return slot }
        return nil
    }

    public func kind(of slot: Int) -> Kind? {
        guard slot >= 0, slot < Self.capacity, busy[slot] else { return nil }
        return kinds[slot]
    }


    // MARK: - Lengths

    /// Bytes the device has to report as written for a completion of `kind`.
    ///
    /// A read fills the data descriptor and then the status byte; a write and a
    /// flush write the status byte and nothing else. This is the check that a
    /// short read cannot pass for a whole one - the device says how much it
    /// wrote, and it used to be nobody's business what it said.
    ///
    /// Widened to sixty-four bits so the addition cannot overflow whatever a
    /// caller hands it.
    public static func expectedUsedBytes(
        _ kind      : Kind,
          payloadBytes: UInt32
    ) -> UInt64 {
        switch kind {
            case .read : UInt64(payloadBytes) + 1
            case .write: 1
            case .flush: 1
        }
    }


    // MARK: - Starting and finishing

    /// Records a request as out with the device. `false` when the slot is not one
    /// to use, which is a driver bug and not a device one.
    public mutating func begin(
        slot        : Int,
        kind        : Kind,
        sectors     : UInt32,
        payloadBytes: UInt32,
        deadline    : UInt64
    ) -> Bool {

        guard slot >= 0, slot < Self.capacity, !busy[slot] else { return false }

        busy[slot]      = true
        kinds[slot]     = kind
        requested[slot] = sectors
        expected[slot]  = Self.expectedUsedBytes(kind, payloadBytes: payloadBytes)
        deadlines[slot] = deadline

        let out = outstanding
        if out > highWater { highWater = out }

        return true
    }


    /// Takes a slot back without a completion, for a submission that never
    /// reached the device.
    public mutating func abandon(_ slot: Int) {
        guard slot >= 0, slot < Self.capacity else { return }
        busy[slot] = false
    }


    /// Every check a completion has to pass, in one place.
    ///
    /// One door, deliberately: a caller cannot perform four of the five checks
    /// and forget the fifth, because there is nowhere to do them separately. The
    /// status byte arrives as a closure rather than a value because which byte to
    /// read depends on the slot, and the slot is the first thing this works out -
    /// so a caller that read it beforehand would be reading a byte chosen by the
    /// number the device sent.
    ///
    /// `advance` is how far the used index moved, which is the one check that is
    /// not about this entry at all: a device that jumps the index has finished
    /// things it was never given, and every entry after the jump is somebody
    /// else's memory read as a completion.
    public mutating func complete(
        id     : UInt32,
        length : UInt32,
        advance: UInt16,
        status : (Int) -> UInt8
    ) -> Verdict {

        guard advance >= 1, Int(advance) <= outstanding else {
            return .fault(.tooManyCompletions)
        }

        guard let slot = VirtioQueueMap.slot(of: id, depth: Self.capacity) else {
            return .fault(.unknownChain)
        }

        guard busy[slot] else { return .fault(.notOutstanding) }

        guard UInt64(length) == expected[slot] else { return .fault(.wrongLength) }

        let byte = status(slot)
        guard byte != Self.unwritten else { return .fault(.statusNotWritten) }

        busy[slot] = false

        return .accept(slot: slot, sectors: requested[slot], failed: byte != 0)
    }


    /// Gives up on everything outstanding and says which slots those were.
    ///
    /// The caller owes an answer to whoever was waiting on each of them. That
    /// debt is what a queue has and one request in flight did not: with one, the
    /// only caller was already inside the failing call.
    public mutating func abandonAll() -> InlineArray<4, Bool> {

        let lost = busy
        for slot in 0..<Self.capacity { busy[slot] = false }

        return lost
    }


    // MARK: - Time

    /// Whether `now` is at or past `deadline` on a counter that may have wrapped.
    ///
    /// The subtraction is wrapping and the difference is read as signed, which is
    /// the standard way and the only one that survives the counter going round:
    /// `now < deadline` compares two absolute values and reads every wrap as a
    /// deadline that has already passed. Correct for any interval shorter than
    /// half the counter, which at sixty-two megahertz is a few thousand years.
    public static func reached(_ deadline: UInt64, at now: UInt64) -> Bool {
        Int64(bitPattern: now &- deadline) >= 0
    }


    /// The deadline a request submitted at `now` gets.
    public static func deadline(from now: UInt64, frequency: UInt64) -> UInt64 {
        let (span, overflowed) = frequency.multipliedReportingOverflow(
            by: patienceSeconds
        )

        // A frequency that cannot hold five seconds is not a clock this can
        // reason about. Half the counter keeps the signed comparison above
        // meaningful, which is more useful than a deadline already in the past.
        return now &+ (overflowed ? UInt64.max / 2 : span)
    }


    /// Counter ticks until the first outstanding request is late: `nil` when
    /// nothing is outstanding, zero when one already is.
    ///
    /// Three answers in one call because the caller needs all three and they are
    /// the same question. Nothing outstanding means wait as long as it takes;
    /// zero means stop waiting and start giving up.
    public func timeRemaining(at now: UInt64) -> UInt64? {

        var soonest: UInt64? = nil

        for slot in 0..<Self.capacity where busy[slot] {
            if Self.reached(deadlines[slot], at: now) { return 0 }

            let left = deadlines[slot] &- now
            if let known = soonest, known <= left { continue }

            soonest = left
        }

        return soonest
    }


    /// `counts` counter ticks as scheduler ticks, rounded up and never zero.
    ///
    /// Rounded up because a wait rounded down is a wait that ends before the
    /// deadline it was computed from, so the caller looks, finds nothing late,
    /// and waits again - a poll wearing a timeout's clothes. Never zero for the
    /// same reason.
    ///
    /// The frequency is divided before it is multiplied, which costs less than a
    /// kilohertz of precision on a deadline measured in seconds and cannot
    /// overflow whatever a device claims its counter runs at.
    public static func schedulerTicks(
        counts             : UInt64,
        frequency          : UInt64,
        millisecondsPerTick: UInt64
    ) -> UInt32 {

        let perTick = frequency / 1000 * millisecondsPerTick
        guard perTick > 0 else { return 1 }

        let whole = counts / perTick
        let ticks = counts % perTick == 0 ? whole : whole + 1

        guard ticks > 1 else { return 1 }

        return ticks > UInt64(UInt32.max) ? UInt32.max : UInt32(ticks)
    }
}
