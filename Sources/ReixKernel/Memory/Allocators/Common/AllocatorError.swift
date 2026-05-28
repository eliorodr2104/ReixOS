//
//  AllocatorErrors.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public enum AllocatorError: KernelDiagnostic {
    case bytesNotValid       (_ bytes  : Int)
    case fullMemory
    case addressInvalid      (_ address: PhysicalAddress)
    case addressRangeInvalid (from: PhysicalAddress, to: PhysicalAddress)
    case pageOrderInvalid    (_ order  : UInt8)
    case doubleFreeInvalid

    public var description: String {
        switch self {
            case .bytesNotValid       : "Allocator Error: invalid byte size requested."
            case .fullMemory          : "Allocator Error: memory is full."
            case .addressInvalid      : "Allocator Error: address is out of bounds."
            case .addressRangeInvalid : "Allocator Error: invalid address range."
            case .pageOrderInvalid    : "Allocator Error: invalid page order."
            case .doubleFreeInvalid   : "Allocator Error: attempted to double-free a memory page."
        }
    }

    public var category: ErrorCategory { .allocator }
}
