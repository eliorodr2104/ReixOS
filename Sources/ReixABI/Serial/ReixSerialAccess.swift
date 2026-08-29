//
//  ReixSerialAccess.swift
//  ReixOS
//

/// A checked authority word for one serial channel.
public struct ReixSerialAccess: Equatable {
    public enum Role: UInt8, Equatable {
        case reader = 1
        case writer = 2
    }

    public let role: Role
    public let channel: UInt32

    private static let roleShift: UInt64 = 56
    private static let channelMask: UInt64 = 0x00FF_FFFF

    public init?(role: Role, channel: UInt32) {
        guard channel != 0, UInt64(channel) <= Self.channelMask else { return nil }
        self.role = role
        self.channel = channel
    }

    public var rawValue: UInt64 {
        UInt64(role.rawValue) << Self.roleShift | UInt64(channel)
    }

    public init?(rawValue: UInt64) {
        guard rawValue & 0x00FF_FFFF_FF00_0000 == 0,
              let role = Role(rawValue: UInt8(rawValue >> Self.roleShift)),
              let value = Self.init(role: role, channel: UInt32(rawValue & Self.channelMask))
        else { return nil }
        self = value
    }
}
