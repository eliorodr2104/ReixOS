//
//  MappingFlags.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// Behavioural modifiers attached to a VMA at creation time.
///
/// Designed as an OptionSet because the flags are not mutually
/// exclusive: a stack VMA can be `.growDown | .noReserve`, an mmap of
/// a copy-on-write file can be `.fixed | .copyOnWrite`, and so on.
public struct MappingFlags: OptionSet {
    public let  rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let none        = MappingFlags([])

    /// Request the mapping at the exact address provided; fail rather
    /// than relocating.
    public static let fixed       = MappingFlags(rawValue: 1 << 0)

    /// Mark the underlying pages read-only at PTE level so the first
    /// write fault triggers a copy-on-write allocation.
    public static let copyOnWrite = MappingFlags(rawValue: 1 << 1)

    /// Allow the VMA to extend toward lower addresses on demand (used
    /// for the user stack).
    public static let growDown    = MappingFlags(rawValue: 1 << 2)

    /// Track the VMA without reserving physical pages eagerly: the
    /// first touch will fault and the page-fault handler will allocate.
    public static let noReserve   = MappingFlags(rawValue: 1 << 3)
}
