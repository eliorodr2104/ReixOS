//
//  GlobalLoggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//

typealias SystemLogger = Logger<PL011UART>
private let _logger = SystemLogger(driver: PL011UART())

@_cdecl("putchar")
public func putchar(ch: UInt8) {
    _logger.kputc(ch)
}


// MARK: - Streaming interpolation

/// Builds a kernel log line by streaming every segment straight to the serial
/// driver as it is appended — no intermediate `String`, no heap. Literal
/// segments are `StaticString` (read-only storage); interpolations are written
/// digit-by-digit. Because appends happen while the argument is constructed,
/// tagged log calls take the message as an `@autoclosure` so the prefix is
/// emitted first.
public struct LogInterpolation: StringInterpolationProtocol {
    public typealias StringLiteralType = StaticString

    public init(literalCapacity: Int, interpolationCount: Int) {}

    @inline(__always)
    public mutating func appendLiteral(_ literal: StaticString) { _logger.writeStatic(literal) }

    @inline(__always)
    public mutating func appendInterpolation(_ value: StaticString) { _logger.writeStatic(value) }

    @inline(__always)
    public mutating func appendInterpolation(_ value: String) { _logger.writeString(value) }

    @inline(__always)
    public mutating func appendInterpolation<T: FixedWidthInteger>(_ value: T) {
        if T.isSigned, value < 0 {
            _logger.kputc(45) // '-'
            _logger.writeDec(UInt64(value.magnitude))
        } else {
            _logger.writeDec(UInt64(value))
        }
    }

    @inline(__always)
    public mutating func appendInterpolation<T: FixedWidthInteger>(
        hex value: T,
        uppercase: Bool = false
    ) {
        _logger.writeHex(UInt64(truncatingIfNeeded: value), uppercase: uppercase)
    }
}

public struct LogMessage: ExpressibleByStringInterpolation {
    public typealias StringLiteralType = StaticString
    public typealias StringInterpolation = LogInterpolation

    @inline(__always)
    public init(stringLiteral value: StaticString) { _logger.writeStatic(value) }

    @inline(__always)
    public init(stringInterpolation: LogInterpolation) {}
}


// MARK: - kprint

/// Streams `message` followed by a newline.
@inline(__always)
public func kprint(_ message: LogMessage) {
    _logger.kputc(10)
}

/// Tagged line: `[LEVEL  ] message`. `message` is an autoclosure so the prefix
/// streams before the message segments do.
@inline(__always)
public func kprint(
    _ type     : PrintType = .message,
    _ message  : @autoclosure () -> LogMessage
) {
    _logger.writeString(type.message)
    _logger.kputc(32) // ' '
    _ = message()
    _logger.kputc(10)
}

/// Tagged line: `[LEVEL  ][SYS ] message`. Both prefixes are fixed-width so
/// columns stay aligned across the log.
@inline(__always)
public func kprint(
    _ type     : PrintType,
    _ message  : @autoclosure () -> LogMessage,
    by subsystem: Subsystem
) {
    _logger.writeString(type.message)
    _logger.writeString(subsystem.tag)
    _logger.kputc(32) // ' '
    _ = message()
    _logger.kputc(10)
}

@inline(__always)
public func kprint() {
    _logger.kprint()
}

@inline(__always)
public func kputc(_ val: UInt8) {
    _logger.kputc(val)
}
