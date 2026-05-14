
//
//  PageTableEntry.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

// TODO: Add RXEntry protocol to allow usage with the LinkedList struct.
/// Represents an AArch64 Page Table Entry (PTE) abstraction.
///
/// This structure manages a single descriptor within the page table hierarchy,
/// handling the bit-packing for physical addresses and architectural flags.
@frozen
public struct AArch64PageTableEntry {
    
    /// The raw 64-bit descriptor value stored in the page table.
    /// - Note: This includes the output physical address and memory attributes.
    var rawValue: VirtualAddress
    
    private static let addressMask: UInt64 = 0x0000_FFFF_FFFF_F000
    private static let flagsMask  : UInt64 = 0x0060_0000_0000_04C3 // 0, 1, 6, 7, 10, 53, 54 bits
    private static let mairMask   : UInt64 = 0x7
    private static let shareMask  : UInt64 = 0x03
    
    /// The physical address mapped by this entry.
    ///
    /// Bits [47:12] of the descriptor.
    var physicalAddress: PhysicalAddress {
        get { UInt64(rawValue & Self.addressMask) }
        set {
            let addr = UInt64(newValue) & Self.addressMask
            rawValue = (rawValue & ~Self.addressMask) | addr
        }
    }
    
    /// The MAIR (Memory Attribute Indirection Register) index for this entry.
    ///
    /// Determines the caching policy (e.g., Write-Back, Device Memory).
    var mairIndex: MairIndex {
        get { MairIndex(rawValue: (rawValue >> 2) & Self.mairMask) ?? .normalCacheable }
        set {
            let val = (newValue.rawValue & Self.mairMask) << 2
            rawValue = (rawValue & ~(Self.mairMask << 2)) | val
        }
    }
    
    /// The shareability domain for this memory region.
    var shareability: Shareability {
        get { Shareability(rawValue: (rawValue >> 8) & Self.shareMask) ?? .innerShareable }
        set {
            let val = (newValue.rawValue & Self.shareMask) << 8
            rawValue = (rawValue & ~(Self.shareMask << 8)) | val
        }
    }
    
    /// Architectural flags defining access permissions and state.
    var flags: VirtualPageFlags {
        get { VirtualPageFlags(rawValue: rawValue & Self.flagsMask) }
        set {
            rawValue = (rawValue & ~Self.flagsMask) | (newValue.rawValue & Self.flagsMask)
        }
    }
    
    
    // MARK: - Handlers
    
    /// Returns a boolean value indicating whether the entry is valid and present in memory.
    var isPresent: Bool {
        return flags.contains(.valid)
    }
}
