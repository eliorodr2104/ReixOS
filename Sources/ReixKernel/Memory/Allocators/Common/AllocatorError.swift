//
//  AllocatorErrors.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public enum AllocatorError: Error {
    case bytesNotValid(_ bytes: Int)
    case fullMemory
    case addressInvalid(_ address: PhysicalAddress)
    case addressRangeInvalid(from: PhysicalAddress, to: PhysicalAddress)
    case pageOrderInvalid(_ order: UInt8)
    case doubleFreeInvalid
    
    public var localizedDescription: String {
        switch self {
            case .bytesNotValid:
                "Allocator Error: Invalid byte size requested."
                
            case .fullMemory:
                "Allocator Error: Memory is full."
                
            case .addressInvalid:
                "Allocator Error: Address is out of bounds."
                
            case .addressRangeInvalid:
                "Allocator Error: Invalid address range."
                
            case .pageOrderInvalid:
                "Allocator Error: Invalid page order."
                
            case .doubleFreeInvalid:
                "Allocator Error: Attempted to double-free a memory page."
        }
    }
}
