//
//  LogInterpolation.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//


/// Builds a kernel log line by streaming every segment straight to the sink
/// as it is appended: no intermediate `String`, no heap. Literal segments
/// are `StaticString` (read-only storage); interpolations are written
/// digit-by-digit. Because appends happen while the argument is
/// constructed, every `kprint` overload takes the message as an
/// `@autoclosure` so the record is opened before the first segment lands.
public struct LogInterpolation: StringInterpolationProtocol {
    
    public typealias StringLiteralType = StaticString

    public init(literalCapacity: Int, interpolationCount: Int) {}

    @inline(__always)
    public mutating func appendLiteral(_ literal: StaticString) {
        LogSink.write(literal)
    }

    @inline(__always)
    public mutating func appendInterpolation(_ value: StaticString) { LogSink.write(value) }

    @inline(__always)
    public mutating func appendInterpolation<T: FixedWidthInteger>(_ value: T) {
        if T.isSigned, value < 0 {
            LogSink.put(45) // '-'
            LogSink.writeDec(UInt64(value.magnitude))
            
        } else {
            LogSink.writeDec(UInt64(value))
        }
    }

    @inline(__always)
    public mutating func appendInterpolation<T: FixedWidthInteger>(
        hex value: T,
        uppercase: Bool = false
    ) {
        LogSink.writeHex(UInt64(truncatingIfNeeded: value), uppercase: uppercase)
    }
}
