//
//  TypedShellParameter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellParameter {
    public let label        : StaticString
    public let type         : ShellValueType
    public let required     : Bool
    public let requiresLabel: Bool

    public init(
        _ label        : StaticString,
          type         : ShellValueType = .text,
          required     : Bool = true,
          requiresLabel: Bool = false
    ) {
        self.label = label
        self.type = type
        self.required = required
        self.requiresLabel = requiresLabel
    }
}
