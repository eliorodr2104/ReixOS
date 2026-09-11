//
//  TypedShellParameter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

/// What kind of thing a parameter takes, for whoever is offering candidates.
///
/// The type says `Text`, which is true of a path, a name and a sentence alike.
/// This says which of those, so `help ` offers receivers and `read ` will
/// offer what is on the disk.
public enum ShellParameterSubject: UInt8, Equatable {
    /// Anything: a word, a number, a binding.
    case value

    /// The name of a receiver or of a command.
    case symbol

    /// A place on the disk.
    case path
}

/// What may complete a path parameter.
///
/// The distinction belongs to the signature rather than to the completer: a
/// reader names bytes, while changing directory names a place. A module can
/// therefore add another path-taking command without adding its name to the
/// editor or to a completion switch.
public enum ShellPathTarget: UInt8, Equatable {
    case anything
    case file
    case place
}

public struct TypedShellParameter {
    public let label        : StaticString
    public let type         : ShellValueType
    public let subject      : ShellParameterSubject
    public let pathTarget   : ShellPathTarget
    public let required     : Bool
    public let requiresLabel: Bool

    public init(
        _ label        : StaticString,
          type         : ShellValueType = .text,
          subject      : ShellParameterSubject = .value,
          pathTarget   : ShellPathTarget = .anything,
          required     : Bool = true,
          requiresLabel: Bool = false
    ) {
        self.label = label
        self.type = type
        self.subject = subject
        self.pathTarget = pathTarget
        self.required = required
        self.requiresLabel = requiresLabel
    }
}
