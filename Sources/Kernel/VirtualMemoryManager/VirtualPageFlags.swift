//
//  PageFlags.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualPageFlags: OptionSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    
    public static let none       = VirtualPageFlags([])
    
    public static let valid      = VirtualPageFlags(rawValue: 1 << 0)
    public static let page       = VirtualPageFlags(rawValue: 1 << 1)
    public static let present    = VirtualPageFlags([.valid, .page])
    public static let accessFlag = VirtualPageFlags(rawValue: 1 << 10)
    public static let userAccess = VirtualPageFlags(rawValue: 1 << 6)
    public static let readOnly   = VirtualPageFlags(rawValue: 1 << 7)
    public static let pxn        = VirtualPageFlags(rawValue: 1 << 53) // Privileged Execute Never
    public static let uxn        = VirtualPageFlags(rawValue: 1 << 54) // Unprivileged Execute Never
}
