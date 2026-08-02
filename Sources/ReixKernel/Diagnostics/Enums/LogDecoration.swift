//
//  LogDecoration.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// What a rendered line carries beyond the bytes the record actually holds.
///
/// A `LogRing` record is a header and plain payload, and it has to stay that
/// way: the drain replays it, the panic report quotes it, and a host tool may
/// decode it long after the machine is off. Anything whose only job is to
/// make the line nicer to read is therefore a rendering decision, taken here,
/// once, on the way to the wire.
///
/// One option set rather than a `Bool` per decoration. There was already
/// exactly one flag of this kind, `LogSink.rendersTimestamp`, never written
/// by anything; a second unrelated flag beside it is how a third arrives.
public struct LogDecoration: OptionSet {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// ANSI colour by severity. See `LogLevel.colour`.
    public static let colour = LogDecoration(rawValue: 1 << 0)

    /// The record's raw `CNTVCT_EL0` reading, `[ticks]`, ahead of the
    /// severity prefix.
    ///
    /// Off by default, and this is the reason the flag it replaces existed:
    /// the boot log is this project's regression test, and a counter reading
    /// makes every line of it differ from its baseline. Colour does not,
    /// because the escapes strip cleanly.
    public static let timestamp = LogDecoration(rawValue: 1 << 1)
}
