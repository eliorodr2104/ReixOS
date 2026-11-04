//
//  RXMemoryError.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//


public enum RXMemoryError {
    
    /// Sentinel returned by `brk` / `munmap` when the kernel refuses the
    /// request. Chosen as `UInt64.max` so that arithmetic on user-space
    /// pointers can detect the error without an extra branch.
    static let memoryFailure: UInt64 = UInt64.max
}
