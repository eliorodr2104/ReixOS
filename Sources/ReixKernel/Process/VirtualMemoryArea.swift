//
//  VMA.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

@frozen
public struct VirtualMemoryArea: RXEntry {
    public let startAddress: VirtualAddress
    public let endAddress  : VirtualAddress
    public var permissions : VMAPermissions
    public var backingType : BackingType
    public var mappingFlags: MappingFlags
    
    public var entryID: UInt64 { 0 }
    
    public var prev: UnsafeMutablePointer<Self>?
    public var next: UnsafeMutablePointer<Self>?
}
