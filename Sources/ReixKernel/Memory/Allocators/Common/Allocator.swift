//
//  Allocator.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

public protocol Allocator {
    func alloc(_ bytes: Int) throws(AllocatorError) -> PhysicalPage
    func free(_ page: consuming PhysicalPage) throws(AllocatorError)
    
    func addFreeRange(
        from rawStart: PhysicalAddress,
        to   rawEnd  : PhysicalAddress
    ) throws(AllocatorError)
}
