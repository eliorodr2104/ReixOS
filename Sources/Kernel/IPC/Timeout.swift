//
//  Timeout.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct Timeout {
    
    public var ticks: UInt32
    
    public init(ticks: UInt32) {
        self.ticks = ticks
    }
    
    public static let never = Timeout(ticks: 0xFFFF_FFFF)
    public static let poll  = Timeout(ticks: 0)}
