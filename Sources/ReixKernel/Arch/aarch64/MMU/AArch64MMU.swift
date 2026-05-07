//
//  MMU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct AArch64MMU {
    
    private init() {  }
    
    @_silgen_name("enable_mmu")
    public static func enableMMU(
        lowTable : PhysicalAddress,
        highTable: PhysicalAddress
    )
    
    @_silgen_name("is_mmu_enabled")
    public static func isMMUEnabled() -> Bool
    
    @_silgen_name("flush_tlb")
    public static func flushTLB()

    @_silgen_name("switch_user_address_space")
    public static func switchUserAddressSpace(_ rootTable: PhysicalAddress)
    
}
