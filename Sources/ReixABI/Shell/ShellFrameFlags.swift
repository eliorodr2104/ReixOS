//
//  ShellFrameFlags.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct ShellFrameFlags: OptionSet, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let end = Self(rawValue: 1 << 0)
    public static let error = Self(rawValue: 1 << 1)
    public static let cancelled = Self(rawValue: 1 << 2)

    public static let allowed: Self = [.end, .error, .cancelled]
}
