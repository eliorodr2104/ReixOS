//
//  ReixInputAccess.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

/// A checked authority word for one InputServer session.
public struct ReixInputAccess: Equatable {
    public enum Role: UInt8, Equatable {
        case source = 1
        case consumer = 2
        case focusController = 3
    }

    public let role: Role
    public let session: UInt32

    private static let roleShift: UInt64 = 56
    private static let sessionMask: UInt64 = 0x00FF_FFFF

    public init?(role: Role, session: UInt32) {
        guard session != 0, UInt64(session) <= Self.sessionMask else { return nil }
        self.role = role
        self.session = session
    }

    public var rawValue: UInt64 {
        UInt64(role.rawValue) << Self.roleShift | UInt64(session)
    }

    public init?(rawValue: UInt64) {
        guard rawValue & 0x00FF_FFFF_FF00_0000 == 0,
              let role = Role(rawValue: UInt8(rawValue >> Self.roleShift)),
              let value = Self.init(role: role, session: UInt32(rawValue & Self.sessionMask))
        else { return nil }
        self = value
    }
}
