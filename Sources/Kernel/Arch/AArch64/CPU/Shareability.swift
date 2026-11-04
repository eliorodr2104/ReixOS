//
//  Shareability.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

/// Defines the hardware coherency domain for a memory region.
///
/// Shareability determines which observers (cores, agents) in the system
/// are guaranteed to see consistent data via hardware cache coherency.
public enum Shareability: UInt64 {
    
    /// Memory is private to the current core. No hardware coherency is provided.
    case nonShareable = 0b00
    
    /// Memory is shared across a broader set of observers (e.g., GPU, other clusters).
    case outerShareable = 0b10
    
    /// Memory is shared among cores within the same Inner Shareable domain (e.g., a CPU cluster).
    case innerShareable = 0b11
}
