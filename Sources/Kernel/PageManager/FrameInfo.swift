//
//  FrameInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

@frozen
public struct FrameInfo {
    var refCount: UInt32
    var order   : UInt8
    var flags   : UInt8
    
    private let _padding: UInt16 // Align to 8Bytes
    
    init(
        refCount: UInt32,
        order   : UInt8,
        flags   : UInt8
    ) {
        self.refCount = refCount
        self.order    = order
        self.flags    = flags
        self._padding = 0
    }
    
    init() {
        self.refCount = 0
        self.order    = 0
        self.flags    = 0
        self._padding = 0
    }
}

public struct PageFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    
    public static let none     = PageFlags([])
    public static let reserved = PageFlags(rawValue: 1 << 0)
    public static let kernel   = PageFlags(rawValue: 1 << 1)
    public static let user     = PageFlags(rawValue: 1 << 2)
    public static let dirty    = PageFlags(rawValue: 1 << 3)
}
