//
//  TraceRing.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Fixed-capacity ring of `TraceEvent`, oldest dropped first except while a
/// dump protects unread history; new writes then count as lost instead.
///
/// Lives in `.bss` as a plain `static var`, exactly like `LogRing` and for the
/// same reason: the first records are written before the heap exists and the
/// last ones may be written after it has stopped being trustworthy. Normal
/// images keep 256 slots (8 KiB). The terminal profiling image keeps 1024
/// slots (32 KiB), enough for its fixed mixed-workload interaction window;
/// that extra 24 KiB is absent from production images.
///
/// Records are fixed size, so unlike `LogRing` there is no framing and no
/// header to pack: a slot is written with one struct assignment, which is legal
/// under strict-align codegen because every member of `TraceEvent` is naturally
/// aligned inside a 32-byte record.
///
/// - Invariant: a slot copy and a writer never overlap. Both run with IRQs
///   masked on one core. Snapshot readers may open windows only after copying
///   a whole value and must validate their cursor again before the next copy.
enum TraceRing {

    /// Slots in the ring. Power of two so cursors are masked rather than
    /// divided. Must stay in step with the `InlineArray` size below.
    #if REIX_TERMINAL_PROFILE
    static let capacity: UInt32 = 1024
    #else
    static let capacity: UInt32 = 256
    #endif

    private static let mask: UInt32 = capacity - 1
    
    /// The position a reader that wants only what happens next starts from.
    ///
    /// `TraceExport.attach` takes this so a consumer sees the machine from the
    /// moment it asked and not a replay of whatever the ring still holds, which
    /// for a live view is history it has no timeline to put anywhere.
    static var currentHead: UInt32 { head }

    #if REIX_TERMINAL_PROFILE
    private static var storage = InlineArray<1024, TraceEvent>(repeating: TraceEvent())
    #else
    private static var storage = InlineArray<256, TraceEvent>(repeating: TraceEvent())
    #endif

    /// Monotonic and never wrapped in place: `head &- tail` is the number of
    /// live records and masking happens only at the point of access. Thirty-two
    /// bits wrap after four billion events, which the subtraction absorbs.
    private static var head: UInt32 = 0
    private static var tail: UInt32 = 0

    /// Records overwritten or rejected before anybody dumped them.
    private static var lostEvents: UInt64 = 0
    private static var generation          : UInt64  = 0
    private static var protectedCursor     : UInt32? = nil
    private static var protectionGeneration: UInt64  = 0
    private static var rejectedWrites      : UInt64  = 0

    /// Monotonic even across reset, so an attached exporter can report writes
    /// rejected while a dump protects unread history.
    static var rejected: UInt64 { rejectedWrites }


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
            if protectedCursor == tail {
                lostEvents &+= 1
                rejectedWrites &+= 1
                return
            }
            tail       &+= 1
            lostEvents &+= 1
        }

        storage[Int(head & mask)] = event
        head &+= 1
    }


    /// Empties the ring and forgets what it dropped.
    ///
    /// The cursors move forward rather than back to zero. `drainForExport`
    /// hands monotonic positions out to a reader that keeps them across calls,
    /// and rewinding `head` under one of those would read as the ring having
    /// lapped it four billion times. `head &- tail` is zero either way, which
    /// is the only thing "empty" means here.
    static func reset() {
        tail       = head
        lostEvents = 0
        generation &+= 1
        protectedCursor = nil
        protectionGeneration &+= 1
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


    /// Milestones are written once before the first syscall can dump them.
    static func bootPhase(at index: Int) -> TraceEvent? {
        guard index >= 0, index < bootPhases.count, bootPhases[index].code != 0 else { return nil }
        return bootPhases[index]
    }


    // MARK: - Read path

    /// Captures positions, not pointers. A window may advance the live ring;
    /// it cannot extend this interval or replace one of its records silently.
    struct Snapshot {
        private var cursor    : UInt32
        private let end       : UInt32
        private let generation: UInt64
        private let protection: UInt64
        let lost: UInt64
        private(set) var invalidated = false

        var remaining: Int { Int(end &- cursor) }

        fileprivate init(cursor: UInt32, end: UInt32, generation: UInt64, lost: UInt64, protection: UInt64 = 0) {
            self.cursor     = cursor
            self.end        = end
            self.generation = generation
            self.protection = protection
            self.lost       = lost
        }

        /// Each call must run with IRQs masked. Only the value copy survives
        /// a window; an evicted unread slot or a reset invalidates the suffix.
        mutating func next() -> TraceEvent? {
            guard cursor != end, !invalidated else { return nil }
            guard generation == TraceRing.generation,
                  head &- cursor <= head &- tail else {
                invalidated = true
                return nil
            }
            let event = storage[Int(cursor & mask)]
            cursor &+= 1
            if protection != 0, protection == protectionGeneration {
                protectedCursor = cursor == end ? nil : cursor
            }
            return event
        }

        /// A stale release cannot unprotect a newer dump or a reset ring.
        func release() {
            if protection != 0, protection == protectionGeneration { protectedCursor = nil }
        }
    }

    /// A dump owns the unread suffix, without a second ring allocation. A full
    /// producer rejects and counts new writes until the next copy frees a slot.
    static func protectSnapshot() -> Snapshot? {
        guard protectedCursor == nil else { return nil }
        protectionGeneration &+= 1
        if tail != head { protectedCursor = tail }
        return Snapshot(cursor: tail, end: head, generation: generation,
            lost: lostEvents, protection: protectionGeneration)
    }

    static func snapshot() -> Snapshot {
        Snapshot(cursor: tail, end: head, generation: generation, lost: lostEvents)
    }

    /// A fixed interval even if the body lets a writer run. Callers needing
    /// loss disclosure keep `Snapshot` and inspect `invalidated` themselves.
    @discardableResult
    static func forEachEvent(_ body: (TraceEvent) -> Void) -> Int {
        var snapshot = snapshot()
        var visited = 0
        while let event = snapshot.next() {
            body(event)
            visited += 1
        }
        return visited
    }


    // MARK: - Export path
    
    /// Visits at most `max` records `cursor` has not seen, oldest first, and
    /// leaves the ring exactly as it was found.
    ///
    /// A second reader alongside `forEachEvent`, wanting the opposite thing: a
    /// dump is a snapshot of the whole history and must repeat itself, an
    /// export is a stream and must not. The two cannot disturb each other
    /// because the only state a drain moves is the caller's own `cursor`.
    ///
    /// `max` bounds what one tick pays. Anything left over is not lost: it
    /// stays in the ring and the next drain resumes where this one stopped,
    /// unless the writer laps the cursor first.
    ///
    /// - Returns: how many records were evicted before the cursor reached them,
    ///   which the caller reports as dropped. Records actually visited are
    ///   counted by `body`, which is handed every one of them.
    /// - Invariant: as everywhere else in this file, the caller must have IRQs
    ///   masked so no emit can evict underneath the drain.
    static func drainForExport(
        from cursor: inout UInt32,
        max        : Int,
        _    body  : (TraceEvent) -> Void
    ) -> Int {
        let live   = head &- tail
        let unseen = head &- cursor

       var skipped = 0
        if unseen > live {
            skipped = Int(unseen &- live)
            cursor  = tail
        }

        var remaining = max
        while cursor != head, remaining > 0 {
            body(storage[Int(cursor & mask)])

            cursor    &+= 1
            remaining &-= 1
        }

        return skipped
    }
}
