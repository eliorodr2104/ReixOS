//
//  Address.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

public typealias PhysicalAddress = UInt64
public typealias VirtualAddress  = UInt64

extension VirtualAddress {
    // VMM Levels
    var l0: Int { Int((self >> 39) & 0x1FF) } // L0
    var l1: Int { Int((self >> 30) & 0x1FF) } // L1
    var l2: Int { Int((self >> 21) & 0x1FF) } // L2
    var l3: Int { Int((self >> 12) & 0x1FF) }
    
}
