//
//  PageFlags.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


public struct PhysicalPageFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    
    public static let none     = PhysicalPageFlags([])
    public static let reserved = PhysicalPageFlags(rawValue: 1 << 0)
    public static let kernel   = PhysicalPageFlags(rawValue: 1 << 1)
    public static let user     = PhysicalPageFlags(rawValue: 1 << 2)
    public static let dirty    = PhysicalPageFlags(rawValue: 1 << 3)
}
