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
    
    public static var errorMessageAllocation = "Failed to allocate VirtualMemoryArea on the kernel heap"

    public let startAddress: VirtualAddress      // 8 Byte
    public let endAddress  : VirtualAddress      // 8 Byte
    public var permissions : VMAPermissions      // 8 Byte
    
    public var prev: UnsafeMutablePointer<Self>? // 8 Byte
    public var next: UnsafeMutablePointer<Self>? // 8 Byte
    
    public var backingType : BackingType         // 1 Byte
    public var mappingFlags: MappingFlags        // 1 Byte
    
    
    public var entryID: UInt64 { startAddress }

    /// Total size of the range in bytes. Cheap pure arithmetic, no
    /// extra storage cost.
    public var size: UInt64 { endAddress - startAddress }
    
    
    init(
        startAddress: VirtualAddress,
        endAddress  : VirtualAddress,
        permissions : VMAPermissions,
        prev        : UnsafeMutablePointer<Self>? = nil,
        next        : UnsafeMutablePointer<Self>? = nil,
        backingType : BackingType,
        mappingFlags: MappingFlags
    ) {
        self.startAddress = startAddress
        self.endAddress   = endAddress
        self.permissions  = permissions
        self.prev         = prev
        self.next         = next
        self.backingType  = backingType
        self.mappingFlags = mappingFlags
    }
}
