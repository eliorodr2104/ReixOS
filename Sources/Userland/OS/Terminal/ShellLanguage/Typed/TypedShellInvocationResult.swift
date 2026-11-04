//
//  TypedShellInvocationResult.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum TypedShellInvocationResult {
    case success(ShellValue)
    case sequence(ShellSequence)
    case materializationLimit(Int)
    case failure(UInt32)
}
