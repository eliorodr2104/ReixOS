//
//  GlobalLoggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//

typealias SystemLogger = Logger<PL011UART>

/// The UART side of the logger. Reached only from `LogSink`, which decides
/// whether a byte goes here now or into `LogRing` first.
let _logger = SystemLogger(driver: PL011UART())


/// Userland console output.
///
/// Deliberately bypasses `LogSink`: a `putchar` is a lone character with no
/// record around it, and the console a process is typing into must stay
/// unbuffered no matter what the kernel log is doing.
@_cdecl("putchar")
public func putchar(ch: UInt8) {
    _logger.kputc(ch)
}


// MARK: - kprint

/// Streams `message` followed by a newline, with no severity prefix.
///
/// `@autoclosure` even though there is no prefix to emit first: the record
/// has to be open before the interpolation starts pushing bytes, or in
/// deferred mode the bytes have nowhere to land.
@inline(__always)
public func kprint(_ message: @autoclosure () -> LogMessage) {
    LogSink.beginRecord(level: nil, tag: nil)
    _ = message()
    LogSink.endRecord()
}

/// Tagged line: `[LEVEL  ] message`. `message` is an autoclosure so the
/// prefix streams before the message segments do.
@inline(__always)
public func kprint(
    _ type     : PrintType = .message,
    _ message  : @autoclosure () -> LogMessage
) {
    LogSink.beginRecord(level: type, tag: nil)
    _ = message()
    LogSink.endRecord()
}

/// Bare newline. Still a record, so a blank separator line keeps its place
/// in the ring instead of being reordered around the lines it separates.
@inline(__always)
public func kprint() {
    LogSink.beginRecord(level: nil, tag: nil)
    LogSink.endRecord()
}

/// Raw byte, outside any record: same contract as `putchar`.
@inline(__always)
public func kputc(_ val: UInt8) {
    _logger.kputc(val)
}
