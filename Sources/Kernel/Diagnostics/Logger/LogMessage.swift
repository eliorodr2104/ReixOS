//
//  LogMessage.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//


public struct LogMessage: ExpressibleByStringInterpolation {
    public typealias StringLiteralType = StaticString
    public typealias StringInterpolation = LogInterpolation

    @inline(__always)
    public init(stringLiteral value: StaticString) { LogSink.write(value) }

    @inline(__always)
    public init(stringInterpolation: LogInterpolation) {}
}
