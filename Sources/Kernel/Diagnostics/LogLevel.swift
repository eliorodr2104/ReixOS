//
//  LogLevel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// Severity tag prepended to every kernel log line.
///
/// The width of the formatted prefix is fixed at 9 characters
/// (brackets included) so consecutive lines align visually in any
/// serial-attached terminal.
///
/// Unlike the `PrintType` it replaces, the level carries a raw value and
/// an ordering, because that ordering *is* the filter: a `Loggable`
/// subsystem declares the lowest level it emits and everything below it
/// is dropped. `boot` and `panic` deliberately sort above every threshold
/// an operator would sensibly configure, so bring-up lines and the last
/// words of a dying kernel can never be filtered away.
public enum LogLevel: UInt8, Comparable {
    case debug   = 0
    case info    = 1
    case message = 2
    case warning = 3
    case error   = 4
    case boot    = 5
    case panic   = 6

    /// Fixed-width severity prefix.
    ///
    /// `StaticString` rather than `String`: the bytes already live in
    /// read-only storage, so the sink can stream them without any of the
    /// `String` machinery in between.
    var prefix: StaticString {
        switch self {
            case .debug  : "[ DEBUG ]"
            case .info   : "[ INFO  ]"
            case .message: "[MESSAGE]"
            case .warning: "[WARNING]"
            case .error  : "[ ERROR ]"
            case .boot   : "[ BOOT  ]"
            case .panic  : "[ PANIC ]"
        }
    }

    /// SGR sequence that colours a line of this severity, or `nil` for the
    /// one level that keeps the terminal's own foreground.
    ///
    /// Never stored in a record: `LogLine` writes it around the bytes on
    /// their way to the wire, so the ring keeps plain payload and the same
    /// record renders coloured or not depending on who is reading.
    ///
    /// Severity is carried by **hue**, and the hues are the eight the
    /// terminal remaps to its own theme (30-39), never the bright range.
    /// That is what makes the scheme survive a light background: bright
    /// yellow on white is unreadable, `33` is the theme's own dark yellow.
    /// It also means no two levels differ only in brightness, so a palette
    /// that renders bold poorly loses no information at all.
    ///
    /// `.info` is uncoloured on purpose. It is the ordinary case and most of
    /// the log, so leaving it in the default foreground is what makes any
    /// colour at all mean something.
    ///
    /// `.error` and `.panic` are the two that must survive being scrolled
    /// past. Red is the one convention no reader has to learn, and panic
    /// takes the background rather than the foreground so it lands as a
    /// filled bar and cannot be mistaken for an error.
    var colour: StaticString? {
        switch self {
            case .debug  : "\u{1B}[35m"      // magenta
            case .info   : nil               // the terminal's own foreground
            case .message: "\u{1B}[32m"      // green
            case .warning: "\u{1B}[33m"      // yellow
            case .error  : "\u{1B}[1;31m"    // red, bold as reinforcement
            case .boot   : "\u{1B}[36m"      // cyan
            case .panic  : "\u{1B}[1;37;41m" // white on red
        }
    }


    @_transparent
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}


/// Compatibility spelling for the `kprint` call sites written before the
/// level gained an ordering, so they can migrate to `Loggable` one file at
/// a time instead of in a single sweep.
public typealias PrintType = LogLevel
