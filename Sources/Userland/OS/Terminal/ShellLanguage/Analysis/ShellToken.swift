//
//  ShellToken.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What a run of bytes is, before anything asks what it means.
///
/// Lexical only: `a.txt` is a name, a dot and a name here, because whether it
/// is one word or a member of something is a question about the call it sits
/// in, and this reads bytes.
public enum ShellTokenKind: UInt8, Equatable {
    case name
    case keyword
    case number
    case text
    case path
    case placeholder
    case dot
    case comma
    case colon
    case assign
    case openParenthesis
    case closeParenthesis
    case openBrace
    case closeBrace
    case operatorSymbol
    case newline

    /// A byte that begins nothing this language has.
    case unknown
}

/// How finished a token is, which is the difference between reading a line and
/// reading a line somebody is still typing.
public enum ShellTokenState: UInt8, Equatable {
    /// Complete and well formed.
    case valid

    /// Opened and never closed: a quote with no partner. The token stands, and
    /// what came before it is not thrown away with it.
    case unterminated

    /// Ends where the input ends, so it can still become longer. What
    /// completion has something to say about.
    case growing

    /// A byte that starts nothing.
    case invalid
}

public struct ShellToken: Equatable {
    public let kind : ShellTokenKind
    public let state: ShellTokenState

    /// Offsets into the revision this was read from. Bounded by the editor's
    /// own capacity, which is why they fit in sixteen bits.
    public let start: UInt16
    public let count: UInt16

    public init(
        kind : ShellTokenKind,
        state: ShellTokenState,
        start: UInt16,
        count: UInt16
    ) {
        self.kind = kind
        self.state = state
        self.start = start
        self.count = count
    }

    public var span: Span { Span(start: Int(start), count: Int(count)) }
    public var end : Int { Int(start) + Int(count) }
}
