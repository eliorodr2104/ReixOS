//
//  ShellSequenceFailure.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum ShellSequenceFailure: Error, Equatable {
    case materializationLimit(Int)
}
