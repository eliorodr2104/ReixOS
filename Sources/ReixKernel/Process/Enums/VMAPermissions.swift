//
//  VMAType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public struct VMAPermissions: OptionSet {
    public let  rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    
    public static let none    = VMAPermissions([])
    public static let read    = VMAPermissions(rawValue: 1 << 0)
    public static let write   = VMAPermissions(rawValue: 1 << 1)
    public static let execute = VMAPermissions(rawValue: 1 << 2)
    public static let user    = VMAPermissions(rawValue: 1 << 3)
    public static let shared  = VMAPermissions(rawValue: 1 << 4)
}
