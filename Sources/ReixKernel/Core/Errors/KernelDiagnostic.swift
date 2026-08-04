//
//  KernelDiagnostic.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// A kernel error that can say what it is without owning any memory.
public protocol KernelDiagnostic: Error {
    var description: StaticString { get }
}
