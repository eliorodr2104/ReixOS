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
    /// access. Only a data write on a copy-on-write region is serviceable;
    /// every other one is a segfault.
    case permission

    /// Alignment fault on a strictly-aligned access.
    case alignment

    /// Access-flag fault: PTE present but the access flag bit is clear.
    case access
}


/// What the faulting instruction was trying to do.
///
/// The cause says why the walk refused, this says what was asked. Both are
/// needed to tell a copy-on-write write apart from an instruction fetch on an
/// NX page, which raise the same permission fault on the same descriptor.
///
/// Built from the exception class (instruction abort against data abort) and,
/// for a data abort, the `WnR` bit of the ISS, so the VMA layer stays free of
/// any AArch64-specific knowledge.
public enum FaultAccess {

    /// The PC was pointed at the page: an instruction abort.
    case instructionFetch

    /// A load: a data abort with `WnR` clear.
    case read

    /// A store or a cache-maintenance write: a data abort with `WnR` set.
    case write

    /// How the access is named in a diagnostic line.
    public var label: StaticString {
        switch self {
            case .instructionFetch: "fetch"
            case .read            : "read"
            case .write           : "write"
        }
    }
}
