//
//  LogSink.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// The single funnel every kernel log byte passes through.
///
/// `LogInterpolation` streams a line one segment at a time, straight out of
/// the argument as it is being built: there is no message value anywhere,
/// which is exactly why there was nowhere to put a buffer. The only place a
/// ring can be spliced in is *underneath* the byte writer, and that is what
/// this enum is: the indirection between "the formatter produced a byte"
/// and "the byte reached the wire".
///
/// Everything routes on `LogRing.isRecording` rather than on `mode`, so a
/// byte emitted outside a record, a `putchar` or the drain's own output,
/// always goes straight out and can never end up recursively buffered.
public enum LogSink {

    /// Where log bytes go.
    public enum Mode: Equatable {

        /// Recorded *and* written straight out, one busy-waited byte at a
        /// time. Roughly 5 ms for a 60-character line at 115200 baud, i.e.
        /// half a scheduler quantum spent inside `kprint`.
        ///
        /// The recording half is not redundant. A panic quotes the tail of
        /// the ring to show what led up to it, and a mode that only wrote
        /// through would leave that ring empty: the history would exist
        /// solely as bytes already gone down a wire nobody was capturing.
        case synchronous

        /// Into `LogRing` only, to be flushed later by `drain(budget:)`.
        case deferred

        /// Straight out, recording nothing.
        ///
        /// The panic path, and only it. The report reads the ring while it
        /// prints, so anything it recorded would append to the very history
        /// it is quoting: the block would start reporting itself.
        case direct
    }

    /// Boots `.synchronous`: IRQs are masked for the whole of `Kernel.boot`,
    /// so nothing could drain a ring before the first `eret` anyway, and the
    /// boot log, which is this project's regression test, has to reach the
    /// wire in statement order. `Kernel` flips this to `.deferred` on the
    /// last instruction before user space starts.
    public static var mode: Mode = .synchronous

    /// Whether the record currently open also goes straight to the wire.
    ///
    /// Latched once in `beginRecord` rather than re-derived per byte, so a
    /// line that began synchronously finishes that way even if something
    /// changes the mode midway through it.
    private static var teeing = false

    /// Whether the record currently open has an SGR sequence still to close.
    ///
    /// Latched for the same reason as `teeing`, and from `LogLine.heading`'s
    /// own answer rather than from a second reading of the flags: the reset
    /// is owed by whoever opened the colour, and only `heading` knows it did.
    private static var colourOpen = false

    private static var queueing = false

    private static var transmitQueue = SerialTransmitQueue()

    /// What a rendered line carries beyond the record's own bytes.
    ///
    /// Colour on, timestamps off. See `LogDecoration`, which is one switch
    /// rather than two because it subsumes the `rendersTimestamp` flag that
    /// used to sit here.
    public static var decoration: LogDecoration = [.colour]

    /// Maximum UART readiness probes performed by one timer tick.
    public static let tickBudget = 32

    public static var droppedTransmissionRecords: UInt64 {
        transmitQueue.droppedRecords
    }


    // MARK: - Record framing

    /// Opens a log record.
    ///
    /// `level == nil` is the bare `kprint(_:)` form: no severity prefix, no
    /// tag, no separating space.
    @inline(never)
    static func beginRecord(level: LogLevel?, tag: StaticString?) {
        teeing     = writesThrough(level)
        colourOpen = false
        queueing   = mode == .deferred && !teeing
        let recording = records()
        let timestamp = recording ? Arch.Timer.counterUnordered() : 0

        if queueing {
            transmitQueue.beginRecord()
            if decoration.contains(.timestamp) {
                transmitQueue.append(91)
                transmitDec(timestamp)
                transmitQueue.append(93)
            }
            colourOpen = LogLine.heading(
                level   : level,
                tag     : tag.map(LogLine.Tag.literal) ?? .untagged,
                coloured: decoration.contains(.colour),
                into    : { transmitQueue.append($0) }
            )
        }

        if teeing {
            colourOpen = LogLine.heading(
                level   : level,
                tag     : tag.map(LogLine.Tag.literal) ?? .untagged,
                coloured: decoration.contains(.colour),
                into    : { _logger.kputc($0) }
            )
        }

        guard recording else { return }

        LogRing.begin(
            level    : level?.rawValue ?? LogRing.rawLevel,
            tag      : tag,
            timestamp: timestamp
        )
    }


    /// Closes the record opened by `beginRecord`.
    ///
    /// Discriminates on `LogRing.isRecording` instead of on `mode` so a
    /// line that started synchronously still finishes synchronously even if
    /// something flipped the mode halfway through it.
    @inline(never)
    static func endRecord() {
        if LogRing.isRecording {
            LogRing.end()

            // Written through as it was built, so the drain owes it nothing:
            // the ring keeps it as history, not as output still pending.
            if teeing || queueing { LogRing.markFlushed() }
        }

        if teeing {
            LogLine.trailer(closing: colourOpen) { _logger.kputc($0) }
        } else if queueing {
            LogLine.trailer(closing: colourOpen) { transmitQueue.append($0) }
            transmitQueue.endRecord()
        }

        colourOpen = false
        queueing = false
    }


    /// Whether the line now opening is kept in the ring.
    ///
    /// `.direct` says no because the panic path is reading the ring while it
    /// prints. `.deferred` says no for a line that is teeing, which there
    /// means a panic: the ring is a queue of output still owed, not a history,
    /// so recording bytes already on the wire would only send them twice.
    ///
    /// Reads `teeing`, so `beginRecord` has to latch that first.
    @inline(__always)
    private static func records() -> Bool {
        switch mode {
            case .synchronous: true
            case .deferred   : !teeing
            case .direct     : false
        }
    }


    /// Whether this line also has to be on the wire before the next
    /// instruction retires.
    ///
    /// True in every mode but `.deferred`, and true even there for a panic:
    /// a panic runs when there may be nobody left alive to drain the ring,
    /// so it can never be left sitting in one.
    @inline(__always)
    private static func writesThrough(_ level: LogLevel?) -> Bool {
        mode != .deferred || level == .panic
    }


    // MARK: - Streaming primitives (no trailing newline)

    /// Routes one byte: into the open record if there is one, onto the wire
    /// if this line is teeing. Both at once is what `.synchronous` means.
    ///
    /// A byte emitted *outside* a record goes to the wire whatever `teeing`
    /// happens to hold, because that flag is stale between records. That
    /// preserves the property the original routing had: a stray `put` can
    /// never be swallowed, and can never be recursively buffered either.
    /// `write` below answers the same two questions the same way.
    @inline(never)
    static func put(_ byte: UInt8) {
        let recording = LogRing.isRecording

        if recording { LogRing.appendPayload(byte) }
        if queueing { transmitQueue.append(byte) }
        if teeing || !recording { _logger.kputc(byte) }
    }


    @inline(never)
    static func write(_ value: StaticString) {
        let recording = LogRing.isRecording

        if recording { LogRing.appendPayload(value) }
        if queueing { transmitQueue.append(value) }
        if teeing || !recording { _logger.writeStatic(value) }
    }


    @inline(never)
    static func writeDec(_ value: UInt64) {
        if value == 0 {
            put(48) // '0'
            return
        }

        var n                = value
        var divisor: UInt64  = 1
        var temp             = n

        while temp >= 10 {
            temp    /= 10
            divisor *= 10
        }

        while divisor > 0 {
            let digit = n / divisor
            put(UInt8(48 + digit))
            n %= divisor
            divisor /= 10
        }
    }


    @inline(never)
    static func writeHex(_ value: UInt64, uppercase: Bool) {
        if value == 0 {
            put(48) // '0'
            return
        }

        let alpha : UInt8 = uppercase ? 55 : 87 // 'A'-10 / 'a'-10
        var started       = false
        var shift         = 60

        while shift >= 0 {
            let nibble = Int((value >> UInt64(shift)) & 0xF)
            if nibble != 0 { started = true }
            if started {
                put(nibble < 10 ? UInt8(48 + nibble) : alpha &+ UInt8(nibble))
            }
            shift -= 4
        }
    }


    // MARK: - Drain

    /// Sends at most `budget` queued bytes and stops immediately if TX is full.
    @discardableResult
    public static func drain(budget: Int = .max) -> Int {
        guard mode == .deferred, budget > 0 else { return 0 }

        return drain(budget: budget) { _logger.tryKputc($0) }
    }

    static func drain(budget: Int, _ put: (UInt8) -> Bool) -> Int {
        guard mode == .deferred, budget > 0 else { return 0 }

        return transmitQueue.drain(budget: budget, put)
    }

    static var transmissionAvailable: Int {
        transmitQueue.available
    }

    @discardableResult
    static func beginTransmission(reserving reservedBytes: Int = 0) -> Bool {
        transmitQueue.beginRecord(reserving: reservedBytes)
    }

    static func transmit(_ byte: UInt8) {
        transmitQueue.append(byte)
    }

    static func transmit(_ value: StaticString) {
        transmitQueue.append(value)
    }

    @discardableResult
    static func endTransmission() -> Bool {
        transmitQueue.endRecord()
    }

    static func transmitDec(_ value: UInt64) {
        if value == 0 {
            transmit(48)
            return
        }

        var divisor: UInt64 = 1
        while value / divisor >= 10 { divisor *= 10 }

        var rest = value
        while divisor > 0 {
            transmit(UInt8(48 &+ (rest / divisor)))
            rest %= divisor
            divisor /= 10
        }
    }

    static func transmitHex(_ value: UInt64) {
        guard value != 0 else {
            transmit(48)
            return
        }

        var started = false
        var shift = 60

        while shift >= 0 {
            let nibble = Int((value >> UInt64(shift)) & 0xF)
            if nibble != 0 { started = true }
            if started {
                transmit(nibble < 10 ? UInt8(48 &+ nibble) : UInt8(87 &+ nibble))
            }
            shift -= 4
        }
    }

    /// Pins the sink write-through and recording-off for the rest of the
    /// kernel's life.
    ///
    /// Deliberately does **not** drain. A drain would push whatever was still
    /// queued out ahead of the report, so the last lines before the fault
    /// would appear twice: once loose above the block and once inside it. The
    /// report prints the tail itself, bounded and inside its own delimiters,
    /// which is where a reader, or a host tool, expects to find it.
    ///
    /// The queued lines are not lost by skipping the drain: the report quotes
    /// the ring's history, which spans them.
    ///
    /// `.direct` rather than `.synchronous` for the same reason: a report
    /// that recorded its own lines would append to the history it is in the
    /// middle of reading.
    ///
    /// Colour goes off with it, and this is the single point that decides the
    /// panic block is plain. The block is the one output built to be captured
    /// and fed back to `swift package reix symbolize`, whose markup an escape
    /// landing in the wrong place would break, and it is read from a file at
    /// least as often as from a live terminal. See `PanicLogTail.render`.
    public static func enterPanicMode() {
        mode = .direct

        decoration.remove(.colour)
    }
}
