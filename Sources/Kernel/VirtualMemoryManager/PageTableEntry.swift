
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
    private static let flagsMask  : UInt64 = 0x0060_0000_0000_04C3 // 0, 1, 6, 7, 10, 53, 54 bits
    private static let mairMask   : UInt64 = 0x7
    private static let shareMask  : UInt64 = 0x03
    
    var physicalAddress: PhysicalAddress {
        get { UInt64(rawValue & Self.addressMask) }
        set {
            let addr = UInt64(newValue) & Self.addressMask
            rawValue = (rawValue & ~Self.addressMask) | addr
        }
    }
    
    var mairIndex: MairIndex {
        get { MairIndex(rawValue: (rawValue >> 2) & Self.mairMask) ?? .normalCacheable }
        set {
            let val = (newValue.rawValue & Self.mairMask) << 2
            rawValue = (rawValue & ~(Self.mairMask << 2)) | val
        }
    }
    
    var shareability: Shareability {
        get { Shareability(rawValue: (rawValue >> 8) & Self.shareMask) ?? .innerShareable }
        set {
            let val = (newValue.rawValue & Self.shareMask) << 8
            rawValue = (rawValue & ~(Self.shareMask << 8)) | val
        }
    }
    
    var flags: VirtualPageFlags {
        get { VirtualPageFlags(rawValue: rawValue & Self.flagsMask) }
        set {
            rawValue = (rawValue & ~Self.flagsMask) | (newValue.rawValue & Self.flagsMask)
        }
    }
    
    
    var isPresent: Bool {
        return flags.contains(.valid)
    }
        
    public var isTable: Bool {
        return (rawValue & (1 << 1)) != 0
    }
    
    public var isBlock: Bool {
        return (rawValue & (1 << 0)) != 0 && (rawValue & (1 << 1)) == 0
    }
    
    public static func tableDescriptor(address: UInt64) -> PageTableEntry {
        var entry = PageTableEntry(rawValue: 0)
        entry.physicalAddress = address
        entry.flags = [.valid, .page]
        
        return entry
    }
}
