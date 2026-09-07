//
//  ShellMemberDescriptor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// One property a value of a given schema answers to.
public struct ShellMemberDescriptor {
    public let name   : StaticString
    public let type   : ShellValueType
    public let summary: StaticString

    public init(
        _ name   : StaticString,
          type   : ShellValueType,
          summary: StaticString
    ) {
        self.name = name
        self.type = type
        self.summary = summary
    }
}
