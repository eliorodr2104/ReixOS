//
//  MairIndex.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

/// Represents an index into the Memory Attribute Indirection Register (MAIR).
///
/// This index selects a specific memory attribute configuration (caching policy,
/// gather/reorder/early-write-ack) defined in the MAIR_EL1 system register.
public enum MairIndex: UInt64 {
    /// Normal memory, typically configured as Write-Back, Read-Allocate, and Write-Allocate.
    case normalCacheable = 0 
    
    /// Device memory, typically configured as nGnRE (non-Gathering, non-Reordering, Early-write-ack).
    case deviceMemory = 1
    
    /// Normal memory, explicitly configured as non-cacheable.
    case normalNonCacheable = 2
}
