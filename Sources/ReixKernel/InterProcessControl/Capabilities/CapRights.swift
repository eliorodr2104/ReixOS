//
//  CapRights.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
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
}
