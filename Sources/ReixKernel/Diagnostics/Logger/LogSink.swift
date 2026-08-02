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

    /// What a rendered line carries beyond the record's own bytes.
    ///
    /// Colour on, timestamps off. See `LogDecoration`, which is one switch
    /// rather than two because it subsumes the `rendersTimestamp` flag that
    /// used to sit here.
    public static var decoration: LogDecoration = [.colour]

    /// Bytes the drain may *start* a record on, per timer tick.
    ///
    /// A floor, not a ceiling: the drain stops between records once this many
    /// bytes have gone out and always finishes the record it began. It used
    /// to stop wherever the count ran out, which cost nothing while a line was
    /// plain bytes and became a correctness bug the moment lines could carry
    /// colour. `\u{1B}[33m` is five bytes; split across two ticks the terminal
    /// gets `\u{1B}[3`, then up to 10 ms of user-space output through the same
    /// UART, then `3m`, and it eats the intervening characters as parameters
    /// of the sequence it is still parsing.
    ///
    /// Bytes, not records: a record is whatever length its author made it, so
    /// a record budget bounds nothing. At 115200 8N1 the UART moves ~11.5 KB/s,
    /// which is ~115 bytes in a 10 ms tick, so 32 bytes is a little over a
    /// quarter of the tick, ~2.8 ms, and the rest stays with the scheduler.
    ///
    /// Worst case per tick is now 31 bytes plus one whole rendered line: the
    /// loop enters a record only while `spent < budget`. A line costs 16 bytes
    /// of prefix, 4 to 14 of colour, one newline and its payload; the longest
    /// in the tree renders to 63, so 94 bytes, ~8.2 ms, still inside the tick.
    /// The bound is only as good as the longest line, and the hard ceiling on
    /// that is the ring: `LogRing` truncates a payload before it can exceed
    /// 8 KiB, which is the one case that would cost several ticks.
    ///
    /// It sustains ~3.2 KB/s, some fifty short lines a second, well above the
    /// kernel's steady-state rate; the 8 KiB ring absorbs bursts above it and
    /// takes ~2.6 s to give a full one back.
    public static let tickBudget = 32


    // MARK: - Record framing

    /// Opens a log record.
    ///
    /// `level == nil` is the bare `kprint(_:)` form: no severity prefix, no
    /// tag, no separating space.
    @inline(never)
    static func beginRecord(level: LogLevel?, tag: StaticString?) {
        teeing     = writesThrough(level)
        colourOpen = false

        if teeing {
            colourOpen = LogLine.heading(
                level   : level,
                tag     : tag.map(LogLine.Tag.literal) ?? .untagged,
                coloured: decoration.contains(.colour),
                into    : { _logger.kputc($0) }
            )
        }

        guard records() else { return }

        LogRing.begin(
            level    : level?.rawValue ?? LogRing.rawLevel,
            tag      : tag,
            timestamp: Arch.Timer.counterUnordered()
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
            if teeing { LogRing.markFlushed() }
        }

        if teeing {
            LogLine.trailer(closing: colourOpen) { _logger.kputc($0) }
        }

        colourOpen = false
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
    /// never be swallowed, and can never be recursively buffered either. The
    /// `write` overloads below answer the same two questions the same way.
    @inline(never)
    static func put(_ byte: UInt8) {
        let recording = LogRing.isRecording

        if recording { LogRing.appendPayload(byte) }
        if teeing || !recording { _logger.kputc(byte) }
    }


    @inline(never)
    static func write(_ value: StaticString) {
        let recording = LogRing.isRecording

        if recording { LogRing.appendPayload(value) }
        if teeing || !recording { _logger.writeStatic(value) }
    }


    @inline(never)
    static func write(_ value: String) {
        let recording = LogRing.isRecording

        if recording { LogRing.appendPayload(value) }
        if teeing || !recording { _logger.writeString(value) }
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

    /// Sends whatever the ring still owes the wire, stopping on the first
    /// record boundary past `budget` bytes, and returns how many went out.
    ///
    /// Only `.deferred` owes anything. In the other two modes every byte went
    /// out as it was produced, and `endRecord` said so, so there is nothing
    /// pending however full the ring is.
    ///
    /// The budget is in bytes because that is the unit the cost is in: a full
    /// 8 KiB ring is about 700 ms of UART time at 115200 baud, so an unbounded
    /// drain from the timer tick would swallow dozens of quanta. This buys no
    /// throughput at all, the wire is still 11.5 KB/s; it moves the wait off
    /// the caller, so a `send()` that logs no longer spends 5 ms of its
    /// syscall inside `kprint`.
    ///
    /// A record is atomic here, which is what `tickBudget` being a floor
    /// means: a rendered line carries escape sequences and the wire is shared
    /// with user space, so a line resumed on the next tick would put unrelated
    /// characters inside an SGR sequence the terminal was still parsing. See
    /// `tickBudget` for what that costs.
    ///
    /// Rendering goes through `_logger` directly, with `LogRing.isRecording`
    /// false throughout, so the drain never feeds the ring it is reading. It
    /// advances only the ring's queue cursor, so the history a panic quotes
    /// survives being flushed.
    ///
    /// - Invariant: the caller must have IRQs masked, so no writer can
    ///   evict the record being rendered. See `LogRing`.
    @discardableResult
    public static func drain(budget: Int = .max) -> Int {
        guard mode == .deferred, budget > 0 else { return 0 }

        guard LogRing.hasPending || hasLosses else { return 0 }

        var spent = reportLosses()

        while spent < budget, let record = LogRing.pending() {
            spent &+= render(record)

            LogRing.flushed(record)
        }

        return spent
    }


    /// Puts one whole record on the wire and returns the bytes that cost.
    ///
    /// The count is exact rather than estimated because it is the only thing
    /// bounding the tick: colour and the timestamp are bytes the record does
    /// not carry, and charging the budget for the payload alone would let a
    /// heavily decorated burst run over.
    private static func render(_ record: LogRing.Record) -> Int {
        var written = 0

        if decoration.contains(.timestamp) { written &+= writeStamp(record.timestamp) }

        // `nil` is `LogRing.rawLevel`: a line written with no prefix at all.
        let level = LogLevel(rawValue: record.level)

        let colour = LogLine.heading(
            level   : level,
            tag     : .recorded(record),
            coloured: decoration.contains(.colour)
        ) { byte in
            _logger.kputc(byte)
            written &+= 1
        }

        for i in 0..<record.payloadLength {
            _logger.kputc(LogRing.payloadByte(record, i))
        }

        written &+= record.payloadLength

        LogLine.trailer(closing: colour) { byte in
            _logger.kputc(byte)
            written &+= 1
        }

        return written
    }


    /// `[ticks]`, the raw counter reading the record was stamped with, and
    /// the bytes it took.
    ///
    /// Raw rather than seconds, unlike the panic tail: converting needs the
    /// timer frequency, and the drain runs from the timer interrupt on every
    /// tick of the machine's life.
    private static func writeStamp(_ ticks: UInt64) -> Int {
        _logger.kputc(91) // '['
        writeDec(ticks)
        _logger.kputc(93) // ']'

        return decimalWidth(ticks) &+ 2
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


    /// Whether the ring has anything to confess.
    @inline(__always)
    private static var hasLosses: Bool {
        LogRing.lost > 0 || LogRing.truncated > 0
    }


    /// Says what the ring dropped, and returns the bytes that cost.
    ///
    /// Charged to the caller's budget, which is why it returns a count: a
    /// `drain(budget: 0)` used to emit this and blow the budget it was given.
    /// It is still written whole rather than resumed, so the one tick that
    /// carries it can overrun by up to ~70 bytes; it is emitted once per burst
    /// of loss, not once per tick, and interleaving a half-finished notice
    /// with the records it is about would be worse than the overrun.
    private static func reportLosses() -> Int {
        guard hasLosses else { return 0 }

        var spent = 0

        if LogRing.lost > 0 {
            spent &+= notice("[... ", LogRing.lost, " records lost]")
            LogRing.clearLost()
        }

        if LogRing.truncated > 0 {
            spent &+= notice("[... ", LogRing.truncated, " records truncated]")
            LogRing.clearTruncated()
        }

        return spent
    }


    /// One `[... N somethings]` line, and the bytes it took.
    ///
    /// Plain, and outside `LogLine`: it is the drain talking about itself
    /// rather than a record being replayed, so it carries no severity and
    /// nothing to colour.
    private static func notice(
        _ opening: StaticString,
        _ count  : UInt64,
        _ closing: StaticString
    ) -> Int {
        _logger.writeStatic(opening)
        writeDec(count)
        _logger.writeStatic(closing)
        _logger.kputc(10) // '\n'

        return opening.utf8CodeUnitCount
             &+ decimalWidth(count)
             &+ closing.utf8CodeUnitCount
             &+ 1
    }


    @inline(__always)
    private static func decimalWidth(_ value: UInt64) -> Int {
        var temp  = value
        var width = 1

        while temp >= 10 {
            temp  /= 10
            width &+= 1
        }

        return width
    }
}
