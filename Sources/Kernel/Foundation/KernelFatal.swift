//
//  KernelFatal.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.
//


/// Marker for diagnostics severe enough to abort kernel execution.
///
/// `KernelFatal` is a refinement of `KernelDiagnostic`: every fatal
/// error is a regular diagnostic, but is allowed to drive the panic
/// path. Concrete fatal errors (PPM, allocator, top-level KernelError)
/// gain this conformance to opt-in to `internalPanic`.
public protocol KernelFatal: KernelDiagnostic {}
