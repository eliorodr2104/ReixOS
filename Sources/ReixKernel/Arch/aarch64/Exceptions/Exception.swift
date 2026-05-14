//
//  Exception.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


/// Represents the Exception Class (EC) extracted from the Exception Syndrome Register (ESR).
///
/// The Exception Class (bits [31:26] of ESR_EL1) identifies the primary cause of
/// a synchronous exception, such as software breakpoints or undefined instructions.
public enum Exception: UInt64 {
    
    /// Unknown Exception Class (EC 0x00).
    /// Typically triggered by an unallocated instruction or an unknown event.
    case unknown = 0x00
    
    /// Breakpoint instruction exception (EC 0x32).
    /// Triggered by the execution of a `BRK` instruction in A64.
    case breakpoint = 0x32
    
    /// A human-readable description of the exception.
    ///
    /// - Note: Uses `StaticString` to ensure no heap allocation occurs during a panic,
    /// as the kernel state might be unstable.
    public var message: StaticString {
        switch self {
            case .breakpoint:
                "Breakpoint Exception (BRK)"
                
            case .unknown:
                "Unknown/Undefined Instruction (UDF)"
        }
    }
}
