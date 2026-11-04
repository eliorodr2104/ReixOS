//
//  ShellSchema.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum ShellSchema: UInt16, Equatable {
    case commandResult      = 1
    case fileSystemFindings = 2
    case presentation       = 3
}
