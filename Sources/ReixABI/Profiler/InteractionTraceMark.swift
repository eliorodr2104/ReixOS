//
//  InteractionTraceMark.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

public struct InteractionTraceMark: Equatable {

    public static let maxValue: UInt32 = 0x00FF_FFFF

    public let point      : InteractionTracePoint
    public let correlation: UInt32
    public let value      : UInt32

    public init?(
        point      : InteractionTracePoint,
        correlation: UInt32,
        value      : UInt32
    ) {

        guard correlation != 0, value <= Self.maxValue else { return nil }

        self.point       = point
        self.correlation = correlation
        self.value       = value
    }

    public var packed: UInt64 {
        UInt64(correlation)
            | (UInt64(point.rawValue) << 32)
            | (UInt64(value) << 40)
    }

    public init?(packed: UInt64) {

        let correlation = UInt32(truncatingIfNeeded: packed)
        let pointRaw    = UInt16((packed >> 32) & 0xFF)
        let value       = UInt32((packed >> 40) & UInt64(Self.maxValue))

        guard let point = InteractionTracePoint(rawValue: pointRaw) else { return nil }

        self.init(point: point, correlation: correlation, value: value)
    }
}
