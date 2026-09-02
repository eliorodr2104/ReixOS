//
//  ShellEditorUpdate.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

public struct ShellEditorUpdate {
    public let action: ShellEditorAction
    public let requiresPresentation: Bool

    public init(action: ShellEditorAction, requiresPresentation: Bool) {
        self.action = action
        self.requiresPresentation = requiresPresentation
    }
}
