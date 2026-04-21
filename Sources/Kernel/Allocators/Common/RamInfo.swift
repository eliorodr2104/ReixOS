//
//  RamInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

@frozen
public struct RamInfo {
    public let start  : PhysicalAddress
    public let size   : UInt64
    public let dtbSize: UInt64
}
