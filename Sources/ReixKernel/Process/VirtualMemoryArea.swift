//
//  VMA.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

/// A contiguous half-open virtual address range owned by a process,
/// `[startAddress, endAddress)`, with uniform permissions and backing.
///
/// Layout note: VMAs live as nodes of an intrusive linked list keyed by
/// `startAddress`. Sorting and lookup use the start address as identity.
@frozen
public struct VirtualMemoryArea: RXEntry {

    public let startAddress: VirtualAddress
    public let endAddress  : VirtualAddress
    public var permissions : VMAPermissions
    public var backingType : BackingType
    public var mappingFlags: MappingFlags

    public var entryID: UInt64 { startAddress }

    /// Total size of the range in bytes. Cheap pure arithmetic, no
    /// extra storage cost.
    public var size: UInt64 { endAddress - startAddress }

    public var prev: UnsafeMutablePointer<Self>?
    public var next: UnsafeMutablePointer<Self>?
}
