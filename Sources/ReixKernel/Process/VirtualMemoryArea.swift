//
//  VMA.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

@frozen
public struct VirtualMemoryArea: RXEntry {
    let startAddress: VirtualAddress
    let endAddress  : VirtualAddress
    var permissions : VMAPermissions
    var backingType : BackingType
    var mappingFlags: MappingFlags
    
    public var entryID: UInt64 { 0 }
    
    public var prev: UnsafeMutablePointer<Self>?
    public var next: UnsafeMutablePointer<Self>?
}
