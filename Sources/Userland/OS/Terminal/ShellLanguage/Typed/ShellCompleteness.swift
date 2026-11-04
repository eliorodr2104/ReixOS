//
//  ShellCompleteness.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum ShellCompleteness: Equatable {
    case complete
    case incomplete(indent: Int)
    case invalid(column: Int)
}
