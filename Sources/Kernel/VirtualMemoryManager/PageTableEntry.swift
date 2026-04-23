
//
//  PageTableEntry.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

@frozen
public struct PageTableEntry {
    var rawValue: UInt64
    
    private static let addressMask: UInt64 = 0x0000_FFFF_FFFF_F000
    
    var physicalAddress: PhysicalAddress {
        get { UInt64(rawValue & Self.addressMask) }
        set {
            let addr = UInt64(newValue) & Self.addressMask
            rawValue = (rawValue & ~Self.addressMask) | addr
        }
    }
    
    var flags: VirtualPageFlags {
        get {
            VirtualPageFlags(rawValue: rawValue & ~Self.addressMask)
        }
        set {
            rawValue = (rawValue & Self.addressMask) | newValue.rawValue
        }
    }
    
    var isPresent: Bool {
        return flags.contains(.valid)
    }
    
    var isWritable: Bool {
        return !flags.contains(.readOnly)
    }
}
