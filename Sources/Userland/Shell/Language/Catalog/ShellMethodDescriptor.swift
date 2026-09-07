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
/// The receiver is a value type and not a schema: `filter` belongs to every
/// sequence, whatever its elements are.
public struct ShellMethodDescriptor {
    public let name    : StaticString
    public let receiver: ShellValueType
    public let argument: ShellMethodArgument
    public let result  : ShellValueType
    public let summary : StaticString

    public init(
        _ name    : StaticString,
          receiver: ShellValueType,
          argument: ShellMethodArgument,
          result  : ShellValueType,
          summary : StaticString
    ) {
        self.name = name
        self.receiver = receiver
        self.argument = argument
        self.result = result
        self.summary = summary
    }
}
