//
//  KernelDiagnostic.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Unified contract for every error type produced inside the kernel.
///
/// Each diagnostic exposes a human-readable `description` (sintetica,
/// in technical English) and a `category` that classifies it for log
/// filtering and panic reporting. The cause chain, when present, is
/// not modelled through an existential pointer — it is embedded inside
/// the `description` of each wrapping case so that printing is a single
/// flat string. This keeps the protocol allocation-free under Embedded
/// Swift and avoids fragile existentials on nested error types.
public protocol KernelDiagnostic: Error {
    var description: String     { get }
    var category   : ErrorCategory { get }
}
