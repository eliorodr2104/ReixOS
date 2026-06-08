//
//  CapRights.swift
//  ReixOS
//
//  Capability rights bitset. Shared (kernel installs/checks, userland selects
//  on grant/derive).
//

public struct CapRights: OptionSet {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let send    = CapRights(rawValue: 1 << 0)
    public static let receive = CapRights(rawValue: 1 << 1)
    public static let grant   = CapRights(rawValue: 1 << 2)
    public static let spawn   = CapRights(rawValue: 1 << 3)
    public static let derive  = CapRights(rawValue: 1 << 4)
}
