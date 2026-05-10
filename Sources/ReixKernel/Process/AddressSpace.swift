//
//  AddressSpace.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public typealias ASID = UInt16

@frozen
public struct AddressSpace {
    public let rootTablePhysical: PhysicalPage
    
//    public let vmaManager: VMAManager
    public let asid      : ASID
    
    init(
        rootTablePhysical: consuming PhysicalPage,
//        vmaManager: VMAManager,
        asid      : ASID
    ) {
        self.rootTablePhysical = rootTablePhysical
//        self.vmaManager = vmaManager
        self.asid       = asid
    }
}
