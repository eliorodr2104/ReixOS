//
//  TypedShellFailure.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum TypedShellFailure: Error, Equatable {
    case syntax(column: Int)
    case incomplete
    case programLimit
    case unknownSymbol(ShellText)
    case ambiguousCall(ShellText, Int)
    case wrongArguments(ShellText)
    case type(expected: ShellValueType, actual: ShellValueType)
    case unsupportedMember(ShellText)
    case service(UInt32)
    case materializationLimit(Int)
    case cancelled
}
