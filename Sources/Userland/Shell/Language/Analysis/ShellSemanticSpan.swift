//
//  ShellSemanticSpan.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What a run of bytes means, which is what a colour is picked from.
///
/// Roles and never colours: the shell says `namespace`, and what a namespace
/// looks like belongs to whoever is drawing. A terminal that cannot colour at
/// all still gets a correct answer, and picks nothing.
public enum ShellSemanticRole: UInt8, Equatable {
    case plain
    case keyword
    case namespace
    case command
    case label
    case text
    case number
    case path
    case variable
    case member
    case closure

    /// Not finished, and not wrong either: what is being typed right now.
    case incomplete

    /// Wrong, and finished enough to say so.
    case error
}

public struct ShellSemanticSpan: Equatable {
    public let role : ShellSemanticRole
    public let start: UInt16
    public let count: UInt16

    public init(
        role : ShellSemanticRole,
        start: UInt16,
        count: UInt16
    ) {
        self.role = role
        self.start = start
        self.count = count
    }

    public var span: Span { Span(start: Int(start), count: Int(count)) }
    public var end : Int { Int(start) + Int(count) }
}
