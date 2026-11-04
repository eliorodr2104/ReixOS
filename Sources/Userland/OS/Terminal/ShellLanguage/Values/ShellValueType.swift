//
//  ShellValueType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum ShellValueType: UInt8, Equatable {
    case void
    case boolean
    case number
    case text
    case record
    case sequence
    case any
}
