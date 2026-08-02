//
//  KernelDiagnostic.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

public protocol KernelDiagnostic: Error {
    var description: String        { get }
    var category   : ErrorCategory { get }
}
