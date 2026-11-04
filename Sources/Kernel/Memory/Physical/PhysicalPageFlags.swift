//
//  PageFlags.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


public struct PhysicalPageFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    
    public static let none      = PhysicalPageFlags([])
    public static let reserved  = PhysicalPageFlags(rawValue: 1 << 0)
    public static let kernel    = PhysicalPageFlags(rawValue: 1 << 1)
    public static let user      = PhysicalPageFlags(rawValue: 1 << 2)
    public static let dirty     = PhysicalPageFlags(rawValue: 1 << 3)

    /// First page of a multi-page (> 4 KiB) kernel-heap block allocated
    /// straight from the buddy as an order-N frame, bypassing the slab.
    /// `BucketsHeap.kfree` keys off this bit to return the whole block.
    public static let heapLarge = PhysicalPageFlags(rawValue: 1 << 4)

    /// Internal allocator ownership state. A zero reference count cannot carry
    /// this meaning: block interiors deliberately have no references, while a
    /// corrupt head can lose its last reference before it reaches the buddy.
    /// Keeping the state in a spare flag bit preserves `FrameInfo`'s 8-byte
    /// stride and leaves the all-zero pattern meaning "free".
    static let allocatorOwned = PhysicalPageFlags(rawValue: 1 << 5)
}
