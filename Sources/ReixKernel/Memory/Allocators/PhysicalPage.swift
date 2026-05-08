//
//  PhysicalPage.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

public struct PhysicalPage {
    public let address: PhysicalAddress
    public let order  : UInt8
    
    init(
        address: PhysicalAddress = 0,
        order  : UInt8           = 0
    ) {
        self.address = address
        self.order   = order
    }
}
