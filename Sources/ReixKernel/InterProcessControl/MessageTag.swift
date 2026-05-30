//
//  MessageTag.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct MessageTag {
    public var label: UInt32
    
    public var length: UInt8
    
    public init(
        label : UInt32,
        length: UInt8
    ) {
        self.label  = label
        self.length = length
    }
}
