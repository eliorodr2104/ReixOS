//
//  Address.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

public typealias PhysicalAddress = UInt64
public typealias VirtualAddress  = UInt64

extension VirtualAddress {
    var indices: [Int] {
        [
            Int((self >> 39) & 0x1FF), // L0
            Int((self >> 30) & 0x1FF), // L1
            Int((self >> 21) & 0x1FF) // L2
        ]
    }
}
