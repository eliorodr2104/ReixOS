//
//  TerminalPatchKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum TerminalPatchKind: UInt16, Equatable {
    case insert = 1
    case eraseBackward = 2
    case moveLeft = 3
    case moveRight = 4
    case newline = 5
    case replaceBuffer = 6
    case bell = 7
}
