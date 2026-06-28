//
//  PhysicalPage.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

public struct PhysicalPage: ~Copyable {

    public let address: PhysicalAddress // 8 Byte
    public let order  : UInt8           // 1 Byte
    
    init(
        address: PhysicalAddress = 0,
        order  : UInt8           = 0
    ) {
        self.address = address
        self.order   = order
    }
}
