//
//  TerminalEventKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum TerminalEventKind: UInt16, Equatable {
    case line = 1
    case eof = 2
    case resize = 3
    case interrupt = 4
}
