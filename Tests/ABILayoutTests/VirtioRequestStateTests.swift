//
//  VirtioRequestStateTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import Testing
import ReixABI

/// What a device is allowed to say, and what happens when it says anything else.
///
/// The used ring is the one place in the whole exchange where numbers arrive
/// from outside this machine's control: an id, a length, and an index. The
/// driver used to check two of the three - that the id named a chain it built and
/// a slot it had not already collected - and take the rest on trust. So a device
/// that completed a read having written four bytes instead of four thousand had
/// its answer copied into a client's window, padded with whatever the last
/// request left in the page; and a device that jumped the used index had every
/// entry past the jump read as a completion.
///
/// None of that needs a disk to try, which is the whole reason this state lives
/// apart from the driver. Every test here is a sentence a device might say.
@Suite("Virtio request state")
struct VirtioRequestStateTests {

    private typealias State = VirtioRequestState

    /// Four hundred and ninety-six bytes short of a page: eight sectors.
    private static let payload: UInt32 = 4096

    private static let frequency: UInt64 = 62_500_000


    /// A state with one read outstanding in slot `slot`.
    private func withRead(
        _ slot: Int,
        payload: UInt32 = VirtioRequestStateTests.payload,
        now    : UInt64 = 1_000
    ) -> State {
        var state = State()

        let started = state.begin(
            slot        : slot,
            kind        : .read,
            sectors     : payload / 512,
            payloadBytes: payload,
            deadline    : State.deadline(from: now, frequency: Self.frequency)
        )
        #expect(started)

        return state
    }


    // MARK: - The lengths

    @Test("a completion has to report exactly what its kind writes")
    func expectedLengths() {
        // The data and then the status byte for a read; the status byte alone for
        // everything else, because nothing else has the device writing memory.
        #expect(State.expectedUsedBytes(.read, payloadBytes: 4096) == 4097)
        #expect(State.expectedUsedBytes(.read, payloadBytes: 512) == 513)
        #expect(State.expectedUsedBytes(.write, payloadBytes: 4096) == 1)
        #expect(State.expectedUsedBytes(.flush, payloadBytes: 0) == 1)

        // Not a trap on the way. The payload is a device's own arithmetic by the
        // time it gets here, so the widest thing it can be is not an argument
        // this may die on.
        #expect(State.expectedUsedBytes(.read, payloadBytes: UInt32.max)
                == UInt64(UInt32.max) + 1)
    }


    // MARK: - Completions that are real

    @Test("the completion a healthy device sends is taken")
    func healthyCompletions() {
        for slot in 0..<State.capacity {
            var state = withRead(slot)

            let verdict = state.complete(
                id     : VirtioQueueMap.head(of: slot),
                length : Self.payload + 1,
                advance: 1
            ) { _ in 0 }

            #expect(verdict == State.Verdict.accept(slot: slot, sectors: 8, failed: false))
            #expect(state.idle)
        }

        // A write reports one byte, and a device that failed it says so in the
        // status byte rather than in the length.
        var writing = State()
        #expect(writing.begin(
            slot: 2, kind: .write, sectors: 8, payloadBytes: Self.payload, deadline: 0
        ) == true)

        let written = writing.complete(
            id: VirtioQueueMap.head(of: 2), length: 1, advance: 1
        ) { _ in 1 }
        #expect(written == .accept(slot: 2, sectors: 8, failed: true))

        // A flush carries no data at all, so its own answer is one byte too.
        var flushing = State()
        #expect(flushing.begin(
            slot: 0, kind: .flush, sectors: 0, payloadBytes: 0, deadline: 0
        ) == true)

        let flushed = flushing.complete(id: 0, length: 1, advance: 1) { _ in 0 }
        #expect(flushed == .accept(slot: 0, sectors: 0, failed: false))
    }


    // MARK: - Completions that are not

    @Test("an id no chain of this queue has is refused")
    func idOutOfRange() {
        var state = withRead(0)

        // Past the end of the table, and not a chain head. Both used to be
        // divided into a slot number that indexed something else.
        for id: UInt32 in [12, 99, 0xFFFF_FFFF, 1, 2] {
            let verdict = state.complete(
                id: id, length: Self.payload + 1, advance: 1
            ) { _ in 0 }

            #expect(verdict == .fault(.unknownChain))
        }
    }


    @Test("a slot that was not out with the device is refused")
    func slotNotBusy() {
        var state = withRead(0)

        // Slot 1 is a real chain and nobody submitted it.
        let verdict = state.complete(
            id: VirtioQueueMap.head(of: 1), length: Self.payload + 1, advance: 1
        ) { _ in 0 }

        #expect(verdict == .fault(.notOutstanding))
    }


    @Test("the same completion twice is refused the second time")
    func duplicateCompletion() {
        var state = withRead(3)

        let first = state.complete(
            id: VirtioQueueMap.head(of: 3), length: Self.payload + 1, advance: 1
        ) { _ in 0 }

        #expect(first == .accept(slot: 3, sectors: 8, failed: false))

        // Nothing is outstanding now, so the repeat is caught by the index check
        // before it is caught by the slot: both are refusals and neither is a
        // second answer to a request already answered.
        let again = state.complete(
            id: VirtioQueueMap.head(of: 3), length: Self.payload + 1, advance: 1
        ) { _ in 0 }

        #expect(again == .fault(.tooManyCompletions))

        // And with something else outstanding, the duplicate is refused for what
        // it is: a slot that has already been given back.
        var two = withRead(3)
        #expect(two.begin(
            slot: 0, kind: .read, sectors: 8, payloadBytes: Self.payload, deadline: 0
        ) == true)

        _ = two.complete(
            id: VirtioQueueMap.head(of: 3), length: Self.payload + 1, advance: 1
        ) { _ in 0 }

        let repeated = two.complete(
            id: VirtioQueueMap.head(of: 3), length: Self.payload + 1, advance: 1
        ) { _ in 0 }

        #expect(repeated == .fault(.notOutstanding))
    }


    @Test("a length that is not what that kind writes is refused")
    func wrongLength() {
        // Short: the classic one. A device that writes four bytes and completes
        // has the rest of the page handed over as if it were disk.
        var short = withRead(0)
        let tooShort = short.complete(id: 0, length: 5, advance: 1) { _ in 0 }
        #expect(tooShort == .fault(.wrongLength))

        // Long: it claims to have written past the descriptor it was given.
        var long = withRead(0)
        let tooLong = long.complete(id: 0, length: Self.payload + 2, advance: 1) { _ in 0 }
        #expect(tooLong == .fault(.wrongLength))

        // Status-only for a read: the length a *write* completion has, on a read.
        // Plausible enough to have passed every check there used to be.
        var statusOnly = withRead(0)
        let onlyStatus = statusOnly.complete(id: 0, length: 1, advance: 1) { _ in 0 }
        #expect(onlyStatus == .fault(.wrongLength))

        // And the mirror: a write claiming to have written the data too.
        var writing = State()
        #expect(writing.begin(
            slot: 0, kind: .write, sectors: 8, payloadBytes: Self.payload, deadline: 0
        ) == true)

        let claimedData = writing.complete(
            id: 0, length: Self.payload + 1, advance: 1
        ) { _ in 0 }
        #expect(claimedData == .fault(.wrongLength))
    }


    @Test("a status byte the device never wrote is refused")
    func statusNotWritten() {
        var state = withRead(0)

        let verdict = state.complete(id: 0, length: Self.payload + 1, advance: 1) { _ in
            State.unwritten
        }

        #expect(verdict == .fault(.statusNotWritten))
    }


    @Test("a used index past the number of requests out is refused")
    func indexRunsAhead() {
        var state = withRead(0)

        // One request outstanding, the index says two finished. Everything past
        // the first entry is somebody else's memory read as a completion.
        let ahead = state.complete(id: 0, length: Self.payload + 1, advance: 2) { _ in 0 }
        #expect(ahead == .fault(.tooManyCompletions))

        // Nor may it stand still: a caller only asks when the index moved.
        let still = state.complete(id: 0, length: Self.payload + 1, advance: 0) { _ in 0 }
        #expect(still == .fault(.tooManyCompletions))

        // Four out, four completions: the honest end of the same check.
        var full = State()
        for slot in 0..<State.capacity {
            #expect(full.begin(
                slot: slot, kind: .read, sectors: 8,
                payloadBytes: Self.payload, deadline: 0
            ) == true)
        }

        let last = full.complete(id: 0, length: Self.payload + 1, advance: 4) { _ in 0 }
        #expect(last == .accept(slot: 0, sectors: 8, failed: false))
    }


    // MARK: - Time

    @Test("a deadline is reached when it is reached, and not before")
    func deadlines() {
        let now      = UInt64(1_000_000)
        let deadline = State.deadline(from: now, frequency: Self.frequency)

        #expect(deadline == now + Self.frequency * State.patienceSeconds)

        #expect(!State.reached(deadline, at: now))
        #expect(!State.reached(deadline, at: deadline - 1))
        #expect(State.reached(deadline, at: deadline))
        #expect(State.reached(deadline, at: deadline + 1))
    }


    @Test("a counter that has gone round does not make everything late")
    func counterWrap() {
        // Submitted just before the top of the counter, due just after it. The
        // absolute comparison every naive version writes reads this as a deadline
        // already long past, and fails a request that has not even started.
        let now      = UInt64.max - Self.frequency
        let deadline = State.deadline(from: now, frequency: Self.frequency)

        #expect(deadline < now)                       // it wrapped

        #expect(!State.reached(deadline, at: now))
        #expect(!State.reached(deadline, at: UInt64.max))
        #expect(!State.reached(deadline, at: deadline &- 1))
        #expect(State.reached(deadline, at: deadline))
        #expect(State.reached(deadline, at: deadline &+ 1))

        let state = withRead(0, now: now)
        #expect(state.timeRemaining(at: now) == Self.frequency * State.patienceSeconds)
        #expect(state.timeRemaining(at: deadline) == 0)
    }


    @Test("how long to wait is the soonest deadline, or nothing at all")
    func waitingTime() {
        var state = State()

        // Nothing outstanding is not "wait zero": it is "there is nothing to
        // wait for", and a caller that read those the same way would spin.
        #expect(state.timeRemaining(at: 5_000) == nil)

        #expect(state.begin(
            slot: 0, kind: .read, sectors: 8, payloadBytes: Self.payload, deadline: 3_000
        ) == true)
        #expect(state.begin(
            slot: 1, kind: .read, sectors: 8, payloadBytes: Self.payload, deadline: 2_000
        ) == true)
        #expect(state.begin(
            slot: 2, kind: .read, sectors: 8, payloadBytes: Self.payload, deadline: 9_000
        ) == true)

        #expect(state.timeRemaining(at: 1_000) == 1_000)
        #expect(state.timeRemaining(at: 2_000) == 0)
    }


    @Test("a wait is rounded up to whole scheduler ticks, and never to none")
    func tickConversion() {
        let perTick = Self.frequency / 1000 * 10       // 625_000 counts

        #expect(State.schedulerTicks(
            counts: perTick, frequency: Self.frequency, millisecondsPerTick: 10
        ) == 1)

        #expect(State.schedulerTicks(
            counts: perTick * 500, frequency: Self.frequency, millisecondsPerTick: 10
        ) == 500)

        // Rounded up. A wait rounded down ends before its own deadline, so the
        // caller looks, finds nothing late, and waits again: a poll wearing a
        // timeout's clothes.
        #expect(State.schedulerTicks(
            counts: perTick + 1, frequency: Self.frequency, millisecondsPerTick: 10
        ) == 2)

        // Never zero, whatever is asked.
        #expect(State.schedulerTicks(
            counts: 0, frequency: Self.frequency, millisecondsPerTick: 10
        ) == 1)
        #expect(State.schedulerTicks(
            counts: 1, frequency: Self.frequency, millisecondsPerTick: 10
        ) == 1)

        // A clock this cannot divide by does not take the process down.
        #expect(State.schedulerTicks(
            counts: 1_000, frequency: 0, millisecondsPerTick: 10
        ) == 1)
        #expect(State.schedulerTicks(
            counts: UInt64.max, frequency: Self.frequency, millisecondsPerTick: 10
        ) == UInt32.max)
    }


    // MARK: - Giving up

    @Test("everything out is abandoned at once, and named")
    func abandonEverything() {
        var state = State()

        for slot in 0..<State.capacity {
            #expect(state.begin(
                slot: slot, kind: .read, sectors: 8,
                payloadBytes: Self.payload, deadline: 1_000
            ) == true)
        }

        #expect(state.outstanding == 4)
        #expect(state.highWater == 4)

        let lost = state.abandonAll()

        for slot in 0..<State.capacity { #expect(lost[slot]) }

        #expect(state.idle)
        #expect(state.freeSlot() == 0)

        // The mark is a measurement of the boot and not of the moment, so giving
        // up does not erase it.
        #expect(state.highWater == 4)
    }


    @Test("a slot cannot be handed out twice, or begun out of range")
    func slotDiscipline() {
        var state = withRead(1)

        #expect(state.begin(
            slot: 1, kind: .read, sectors: 8, payloadBytes: Self.payload, deadline: 0
        ) == false)
        #expect(state.begin(
            slot: State.capacity, kind: .read, sectors: 8,
            payloadBytes: Self.payload, deadline: 0
        ) == false)
        #expect(state.begin(
            slot: -1, kind: .read, sectors: 8, payloadBytes: Self.payload, deadline: 0
        ) == false)

        #expect(state.isBusy(1))
        #expect(!state.isBusy(0))
        #expect(!state.isBusy(State.capacity))
        #expect(!state.isBusy(-1))

        state.abandon(1)
        #expect(!state.isBusy(1))
    }


    // MARK: - How big the device is

    @Test("a size is believed once it has been said twice")
    func capacitySettles() {
        var readings: [UInt64] = [32768, 32768]
        var index = 0

        let steady = VirtioCapacity.settled {
            defer { index += 1 }
            return readings[index]
        }
        #expect(steady == 32768)

        // One change and then steady is the case the retry exists for: two
        // registers read separately, and a size that moved between them.
        readings = [0x1_0000_0000, 32768, 32768]
        index = 0

        let afterAChange = VirtioCapacity.settled {
            defer { index += 1 }
            return readings[index]
        }
        #expect(afterAChange == 32768)
    }


    @Test("a size that never settles is refused, and so is nothing")
    func capacityRefused() {
        // A device that answers differently every time. The old code used the
        // last reading, which is a number it had just watched be wrong.
        var index = 0

        let unsettled = VirtioCapacity.settled {
            defer { index += 1 }
            return UInt64(index) + 1
        }
        #expect(unsettled == nil)

        #expect(index == VirtioCapacity.attempts)

        // Stable zero is refused rather than retried: agreeing on nothing is not
        // an agreement worth having, and a bound of zero refuses every request
        // while looking like a disk.
        let nothing = VirtioCapacity.settled { 0 }
        #expect(nothing == nil)
    }
}
