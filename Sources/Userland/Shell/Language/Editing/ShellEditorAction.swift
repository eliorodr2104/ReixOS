//
//  ShellEditorAction.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum ShellEditorAction: Equatable {
    case editing
    case submitted(Int)
    case cancelled
    case eof
    case resized(UInt16, UInt16)
    case refused
}
