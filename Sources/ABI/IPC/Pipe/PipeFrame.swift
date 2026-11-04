//
//  PipeFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct PipeFrame {
    public static let endFlag: UInt32 = 1

    public let count: UInt32
    public let flags: UInt32
    public let token: UInt32

    public init?(count: Int, flags: UInt32, token: UInt32 = 1) {
        guard count >= 0, count <= Int(UInt32.max), token != 0 else { return nil }
        self.init(rawCount: UInt32(count), flags: flags, token: token)
    }

    public init(rawCount: UInt32, flags: UInt32, token: UInt32 = 1) {
        self.count = rawCount
        self.flags = flags
        self.token = token
    }

    public var ends: Bool { flags == Self.endFlag }

    public func checked(extent: UInt64, destinationCapacity: Int, ended: Bool) -> PipeStatus {
        guard !ended else { return .ended }
        guard flags == 0 || flags == Self.endFlag else { return .invalidFrame }
        guard count > 0 || ends else { return .invalidFrame }
        guard destinationCapacity >= 0 else { return .destinationTooSmall }
        guard UInt64(count) <= extent else { return .outOfBounds }
        guard Int(count) <= destinationCapacity else { return .destinationTooSmall }
        return .ok
    }
}
