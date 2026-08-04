//
//  TraceRing.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Fixed-capacity ring of `TraceEvent`, oldest dropped first.
///
/// Lives in `.bss` as a plain `static var`, exactly like `LogRing` and for the
/// same reason: the first records are written before the heap exists and the
/// last ones may be written after it has stopped being trustworthy. 256 slots
/// of 32 bytes is 8 KiB, sized so a burst of syscalls survives long enough to
/// be dumped and no larger.
///
/// Records are fixed size, so unlike `LogRing` there is no framing and no
/// header to pack: a slot is written with one struct assignment, which is legal
/// under strict-align codegen because every member of `TraceEvent` is naturally
/// aligned inside a 32-byte record.
///
/// - Invariant: **producer and consumer can never overlap.** This is
///   `LogRing`'s invariant and it holds here for `LogRing`'s reason: EL1 is
///   non-preemptible with IRQs masked (`daifset #3`) on every path that emits,
///   and the dump runs inside a syscall body with the same mask, so a writer
///   only ever runs between two whole records and so does the walk. That is why
///   no cursor here is atomic and no barrier is issued anywhere in this file.
enum TraceRing {

    /// Slots in the ring. Power of two so cursors are masked rather than
    /// divided. Must stay in step with the `InlineArray` size below.
    static let capacity: UInt32 = 256

    private static let mask: UInt32 = 255

    private static var storage = InlineArray<256, TraceEvent>(repeating: TraceEvent())

    /// Monotonic and never wrapped in place: `head &- tail` is the number of
    /// live records and masking happens only at the point of access. Thirty-two
    /// bits wrap after four billion events, which the subtraction absorbs.
    private static var head: UInt32 = 0
    private static var tail: UInt32 = 0

    /// Records overwritten before anybody dumped them.
    private static var lostEvents: UInt64 = 0


    // MARK: - State

    static var count: Int    { Int(head &- tail) }
    static var lost : UInt64 { lostEvents        }


    // MARK: - Write path

    /// Files one record, evicting the oldest when the ring is full.
    ///
    /// Overwrite-oldest: an emit never blocks and never asks whether anybody is
    /// reading. A profiler that loses the start of a long run still has the end
    /// of it, which is the half that explains what just happened.
    @inline(never)
    static func append(_ event: TraceEvent) {
        if head &- tail == capacity {
            tail       &+= 1
            lostEvents &+= 1
        }

        storage[Int(head & mask)] = event
        head &+= 1
    }


    /// Empties the ring and forgets what it dropped.
    static func reset() {
        head       = 0
        tail       = 0
        lostEvents = 0
    }


    // MARK: - Boot phases

    /// One slot per `TraceBootPhase` id, written once at bring-up and never
    /// evicted. The whole boot emits more events than the ring holds, so by the
    /// time anything can ask for a dump the phases are the records already
    /// gone; eleven write-once slots keep them for the entire uptime instead.
    private static var bootPhases = InlineArray<12, TraceEvent>(repeating: TraceEvent())


    /// Files one bring-up milestone, keyed by its id rather than by arrival.
    static func recordBootPhase(_ event: TraceEvent) {
        guard event.info < 12 else { return }

        bootPhases[Int(event.info)] = event
    }


    /// Visits the recorded milestones in id order and returns how many exist.
    /// Ids are assigned in bring-up order, so this is also oldest first.
    @discardableResult
    static func forEachBootPhase(_ body: (TraceEvent) -> Void) -> Int {
        var visited = 0

        for index in 0..<12 where bootPhases[index].code != 0 {
            body(bootPhases[index])
            visited &+= 1
        }

        return visited
    }


    // MARK: - Read path

    /// Visits every record, oldest first, and leaves the ring exactly as it was
    /// found. Returns how many it visited.
    ///
    /// A walk rather than a consuming drain, because the ring is a history and
    /// not a queue: two dumps in a row must report the same events, and the
    /// second one reporting nothing would be the more surprising answer.
    ///
    /// - Invariant: as everywhere else in this file, the caller must have IRQs
    ///   masked so no emit can evict underneath the walk.
    @discardableResult
    static func forEachEvent(_ body: (TraceEvent) -> Void) -> Int {
        var cursor  = tail
        var visited = 0

        while cursor != head {
            body(storage[Int(cursor & mask)])

            cursor  &+= 1
            visited &+= 1
        }

        return visited
    }
}
