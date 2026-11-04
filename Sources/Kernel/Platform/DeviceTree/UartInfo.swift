//
//  UartInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


@frozen
public struct UartInfo {
    public var baseAddr : UInt64 = 0
    public var type     : UInt32 = 0
    public var irq      : UInt32 = 0
    public var clockFreq: UInt32 = 0
    
    public init() {}
}