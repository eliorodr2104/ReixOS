//
//  ShellMethodDescriptor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What one method takes, which is all the editor needs to offer it.
public enum ShellMethodArgument: UInt8, Equatable {
    case none
    case closure
    case text
}

/// One method the runtime answers on a value, described rather than guessed.
///
/// Methods belong to a type: a list has `filter`, a text has `contains`, and
/// asking a catalog for one asks about the type it is on.
public struct ShellMethodDescriptor {
    public let name    : StaticString
    public let argument: ShellMethodArgument
    public let result  : ShellTypeSchema
    public let summary : StaticString

    public init(
        _ name    : StaticString,
          argument: ShellMethodArgument,
          result  : ShellTypeSchema,
          summary : StaticString
    ) {
        self.name = name
        self.argument = argument
        self.result = result
        self.summary = summary
    }
}
