//
//  CapRights.swift
//  ReixOS
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

    public static let read    = CapRights(rawValue: 1 << 5)
    public static let write   = CapRights(rawValue: 1 << 6)

}
