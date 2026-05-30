//
//  SendOptions.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct SendOptions: OptionSet {
    
    public let rawValue: UInt8
    
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
    
    public static let blocking     = SendOptions(rawValue: 1 << 0)
    public static let transferCaps = SendOptions(rawValue: 1 << 1)
}
