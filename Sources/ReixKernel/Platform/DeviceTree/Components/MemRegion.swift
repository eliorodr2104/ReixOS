//
//  MemRegion.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


@frozen
public struct MemRegion {
    public var base: UInt64 = 0
    public var size: UInt64 = 0
    
    public init() {}
}