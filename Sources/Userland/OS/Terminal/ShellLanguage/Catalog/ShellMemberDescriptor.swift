//
//  ShellMemberDescriptor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// One property a value of a given type answers to.
public struct ShellMemberDescriptor {
    public let name   : StaticString

    /// What reading it gives back, so reaching further into it can be offered
    /// as well: the `first` of a list of files is a file.
    public let type   : ShellTypeSchema
    public let summary: StaticString

    public init(
        _ name   : StaticString,
          type   : ShellTypeSchema,
          summary: StaticString
    ) {
        self.name = name
        self.type = type
        self.summary = summary
    }
}
