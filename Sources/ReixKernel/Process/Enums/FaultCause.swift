//
//  FaultCause.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Classifies the architectural reason behind a user-space memory abort.
///
/// Built from the ESR_EL1 DFSC field by the exception handler before
/// the request reaches the VMA layer, so the VMA layer can stay free of
/// any AArch64-specific knowledge.
public enum FaultCause {

    /// Translation fault: no valid PTE for the faulting VA.
    case translation

    /// Permission fault: PTE exists but its flags forbid the attempted
    /// access (used to drive COW and write-to-read-only segfaults).
    case permission

    /// Alignment fault on a strictly-aligned access.
    case alignment

    /// Access-flag fault: PTE present but the access flag bit is clear.
    case access
}
