//
//  LogLine.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// Everything on a log line that is not the message: the severity prefix,
/// the subsystem tag, the colour around them and the newline that ends it.
///
/// Three paths put the same line on the wire and all three have to agree on
/// it byte for byte, or the boot log stops being comparable against itself:
/// `LogSink` while the line is being streamed, `LogSink.drain` when the ring
/// hands it back a tick later, and `PanicLogTail` when the report quotes it.
/// They used to be three implementations kept in step by a comment.
///
/// They are one implementation here because none of them can reach a byte
/// any other way: the layout is decided in `heading` and `trailer`, and the
/// only thing a caller supplies is where the bytes go. The sinks really are
/// different, `_logger` for two of them and `PanicConsole` for the third,
/// which is exactly what `put` is parameterised over. A fourth caller gets
/// the same bytes by construction rather than by being careful.
///
/// What deliberately stays outside: the timestamp. The drain prints the raw
/// counter reading and the panic tail prints seconds, indented, so there is
/// no shared layout to hoist, only two one-line renderings that each exist
/// once.
enum LogLine {

    /// Where the tag's bytes are.
    ///
    /// A `StaticString` while the line is being written, since that is what
    /// the call site handed in; bytes in the ring once it has been recorded,
    /// since a record never copies its tag out.
    enum Tag {
        case untagged
        case literal (StaticString)
        case recorded(LogRing.Record)
    }


    /// Emits `[ LEVEL ][TAG ] `, preceded by this severity's colour when
    /// `coloured`, and reports whether that colour is still open.
    ///
    /// The return value is the whole handshake with `trailer`: the rule for
    /// whether an SGR sequence was written lives here and nowhere else, so a
    /// caller cannot get the reset wrong by re-deriving it. `LogSink` latches
    /// it across the gap while the message streams.
    ///
    /// `level == nil` is the bare `kprint(_:)` form: no prefix, no tag, no
    /// separating space, and no colour either, which is what keeps the boot
    /// banner and the user-space rules plain ASCII.
    @inline(__always)
    @discardableResult
    static func heading(
        level   : LogLevel?,
        tag     : Tag,
        coloured: Bool,
        into put: (UInt8) -> Void
    ) -> Bool {
        guard let level else { return false }

        var opened = false

        if coloured, let colour = level.colour {
            write(colour, into: put)
            opened = true
        }

        write(level.prefix, into: put)

        switch tag {
            case .untagged            : break
            case .literal (let value ): write(value, into: put)
            case .recorded(let record): writeTag(record, into: put)
        }

        put(32) // ' '

        return opened
    }


    /// Closes the line: the SGR reset `heading` said was owed, then `\n`.
    ///
    /// The reset is per line rather than per run of lines because the wire is
    /// shared. User space writes the same UART from EL0 through
    /// `ConsoleServer`, and a colour left open would bleed into whatever it
    /// printed next.
    @inline(__always)
    static func trailer(closing colour: Bool, into put: (UInt8) -> Void) {
        if colour { write(reset, into: put) }

        put(10) // '\n'
    }


    /// Back to the terminal's own foreground, background and weight.
    private static let reset: StaticString = "\u{1B}[0m"


    @inline(__always)
    private static func write(_ text: StaticString, into put: (UInt8) -> Void) {
        text.withUTF8Buffer { buffer in
            for byte in buffer { put(byte) }
        }
    }


    @inline(__always)
    private static func writeTag(_ record: LogRing.Record, into put: (UInt8) -> Void) {
        for i in 0..<record.tagLength { put(LogRing.tagByte(record, i)) }
    }
}
