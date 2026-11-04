//
//  GicInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


@frozen
public struct GicInfo {
    public var gicdBase: UInt64 = 0
    public var giccBase: UInt64 = 0
    
    public init() {}
}