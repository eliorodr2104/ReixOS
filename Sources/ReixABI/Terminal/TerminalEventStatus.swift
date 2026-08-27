//
//  TerminalEventStatus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum TerminalEventStatus: UInt16, Equatable {
    case ok = 0
    case malformed = 1
    case refused = 2
    case cancelled = 3
}
