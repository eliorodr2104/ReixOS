//
//  UInt64+MessageTag.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//


public extension UInt64 {    
    var packed: MessageTag {
        MessageTag(packed: self)
    }
}
