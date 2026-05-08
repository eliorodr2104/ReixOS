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
    public let asid             : ASID
    
    // Implement VMA
    // let vma      : UnsafeMutablePointer<VMA>
    
    init(
        rootTablePhysical: consuming PhysicalPage,
        asid             : ASID
    ) {
        self.rootTablePhysical = rootTablePhysical
        self.asid              = asid
    }
}
