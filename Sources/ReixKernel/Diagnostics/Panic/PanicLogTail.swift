//
//  PanicLogTail.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// Dumps the last few `LogRing` records into the panic report, leaving the
/// ring exactly as it was found.
///
/// A panic block used to arrive with no history at all: whoever pasted it
/// somewhere had the fault and nothing that led up to it. The ring already
/// holds that history in `.bss`, which survives the fault, so the report
/// carries it inline and the block becomes self-contained.
///
/// Non-consuming is a hard requirement, not a nicety. The report is not
/// necessarily the last reader: a kernel debugger, a second formatter or a
/// human poking at memory over JTAG must see the same records afterwards.
/// A reader that empties the only copy of the evidence is the same class of
/// mistake as a reporter that allocates.
enum PanicLogTail {

    /// Records carried in the report.
    ///
    /// The ring holds roughly two hundred short lines; printing all of them
    /// costs about 700 ms of UART time and buries the four lines a reader
    /// actually opens the block for. Sixteen is about one screen.
    static let limit = 16


    /// Prints the section, rule included.
    ///
    /// - Precondition: `LogRing.isRecording` is false. `DefaultPanicFormatter`
    ///   closes any record a faulted writer left open before calling in here,
    ///   which is what lets the walk below run to `head` instead of stopping
    ///   short at the open one.
    static func emit(limit: Int = limit) {
        PanicConsole.rule("log")

        reportLosses()

        guard let oldest = LogRing.peek() else {
            PanicConsole.write("  (ring empty)")
            PanicConsole.newline()
            return
        }

        // Where the ring's read cursor has to be put back before returning.
        let origin = oldest.cursor

        let total = walk(from: origin) { _ in }
        let older = total > limit ? total &- limit : 0

        if older > 0 {
            PanicConsole.write("  (")
            PanicConsole.writeDec(UInt64(older))
            PanicConsole.write(" older records not shown)")
            PanicConsole.newline()
        }

        var skipped = 0
        _ = walk(from: origin) { record in
            defer { skipped &+= 1 }

            guard skipped >= older else { return }

            render(record)
        }
    }


    // MARK: - Traversal

    /// Runs `body` over every complete record from `origin` to `head`, then
    /// parks the read cursor back on `origin`. Returns how many records were
    /// visited.
    ///
    /// `LogRing` publishes exactly one way to move through the ring,
    /// `peek()` then `retire()`, and both work off the read cursor, so a
    /// traversal is necessarily destructive while it is in flight and has to
    /// be undone at the end. It is safe to do that here and only here: the
    /// panic path runs with interrupts masked, so no writer can evict
    /// anything underneath the walk, and the walk itself is pure arithmetic
    /// over `.bss` that cannot fault.
    ///
    /// This is a workaround, and a small read-only cursor API on `LogRing`
    /// would retire it. See the note on `rewind(to:)`.
    private static func walk(
        from origin: UInt64,
        _    body  : (LogRing.Record) -> Void
    ) -> Int {
        var visited = 0

        // `peek()` stops at a record a faulted writer left open, and each
        // step advances a whole header, so a corrupt ring also terminates.
        while let record = LogRing.peek() {
            body(record)
            LogRing.retire(record)

            visited &+= 1
        }

        rewind(to: origin)

        return visited
    }


    /// Parks `LogRing`'s read cursor on `cursor`.
    ///
    /// `retire` is the only writer of that cursor and it derives the new
    /// position from the geometry of the record handed to it, so a
    /// zero-length record placed one header *before* the target lands the
    /// cursor exactly on the target. It reads as a trick because it is one:
    /// the ring's read API is built for a drain, which only ever moves
    /// forward, and the head and tail cursors themselves are private.
    ///
    /// - Note: the honest fix is a read-only traversal on `LogRing`
    ///   (`forEachRecord`, or a `snapshot() -> (head:tail:)`), which this
    ///   would then call. That file belongs to another change in flight.
    @inline(__always)
    private static func rewind(to cursor: UInt64) {
        LogRing.retire(
            LogRing.Record(cursor: cursor &- UInt64(LogRing.headerSize))
        )
    }


    // MARK: - Rendering

    /// One record, laid out exactly as the drain lays it out, plus a
    /// timestamp and never coloured.
    ///
    /// The layout comes from `LogLine` rather than from a copy of it kept in
    /// step by a comment, which is the only way the tail and the live log can
    /// be diffed against each other at all.
    ///
    /// Timestamps are hidden behind `LogDecoration.timestamp` elsewhere so
    /// the boot log stays byte-comparable against its baseline. Here they are
    /// unconditional: *when*, relative to the fault, is half of what the tail
    /// is for. Seconds rather than the drain's raw ticks, so a line reads on
    /// the same scale as the `Uptime:` field above it.
    ///
    /// `coloured: false` is not an accident of the mode the sink happens to
    /// be in. This block gets pasted into issues and piped through
    /// `reix symbolize`, and plain bytes are what both of those want. See
    /// `LogSink.enterPanicMode`.
    private static func render(_ record: LogRing.Record) {
        PanicConsole.write("  [")
        PanicConsole.writeSeconds(record.timestamp)
        PanicConsole.write("] ")

        // `nil` is `LogRing.rawLevel`: a line written with no prefix at all.
        LogLine.heading(
            level   : LogLevel(rawValue: record.level),
            tag     : .recorded(record),
            coloured: false
        ) { PanicConsole.put($0) }

        for i in 0..<record.payloadLength {
            PanicConsole.put(LogRing.payloadByte(record, i))
        }

        LogLine.trailer(closing: false) { PanicConsole.put($0) }
    }


    /// Records the ring dropped before anybody drained them.
    ///
    /// Read, never cleared: `clearLost()` would make the report the reason
    /// the next reader thinks nothing was lost.
    private static func reportLosses() {
        let lost = LogRing.lost

        guard lost > 0 else { return }

        PanicConsole.write("  (")
        PanicConsole.writeDec(lost)
        PanicConsole.write(" records overwritten before they were flushed)")
        PanicConsole.newline()
    }
}
