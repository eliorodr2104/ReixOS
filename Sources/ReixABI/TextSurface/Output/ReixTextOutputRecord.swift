//
//  ReixTextOutputRecord.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

/// A bounded semantic output record. The payload can straddle a shared ring,
/// hence the two borrowed spans; callers retain ownership for the duration of
/// the presentation call.
public struct ReixTextOutputRecord {
    public static let maximumPayloadBytes = 4095

    public let source      : UInt32
    public let severity    : ReixTextOutputSeverity
    public let kind        : ReixTextOutputKind
    public let payloadKind : ReixTextOutputPayloadKind
    public let payloadCount: Int

    private let first      : UnsafePointer<UInt8>?
    private let firstCount : Int
    private let second     : UnsafePointer<UInt8>?
    private let secondCount: Int

    public init?(
        source     : UInt32,
        severity   : ReixTextOutputSeverity,
        kind       : ReixTextOutputKind,
        payloadKind: ReixTextOutputPayloadKind,
        first      : UnsafePointer<UInt8>?,
        firstCount : Int,
        second     : UnsafePointer<UInt8>? = nil,
        secondCount: Int = 0
    ) {
        guard source != 0,
              firstCount >= 0,
              secondCount >= 0,
              firstCount + secondCount <= Self.maximumPayloadBytes,
              (firstCount == 0) == (first == nil),
              (secondCount == 0) == (second == nil)
        else { return nil }

        self.source = source
        self.severity = severity
        self.kind = kind
        self.payloadKind = payloadKind
        self.payloadCount = firstCount + secondCount
        self.first = first
        self.firstCount = firstCount
        self.second = second
        self.secondCount = secondCount
    }

    public func payloadByte(at index: Int) -> UInt8? {
        guard index >= 0, index < payloadCount else { return nil }
        if index < firstCount { return first![index] }
        return second![index - firstCount]
    }
}
