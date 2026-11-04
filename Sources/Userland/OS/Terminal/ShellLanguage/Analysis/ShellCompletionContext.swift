//
//  ShellCompletionContext.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What kind of thing belongs where the cursor is.
public enum ShellCompletionSubject: UInt8, Equatable {
    /// Nothing worth offering, or nowhere to offer it.
    case none

    /// The head of a statement, where a receiver or a bare verb goes.
    case receiverOrCommand

    /// After `receiver.`: one of that receiver's commands.
    case command

    /// The start of an argument in a written call, where a label goes.
    case label

    /// After `value.`: a member or a method of what that value is.
    case member

    /// An argument's value. What it may be is in `expected`, and a path is
    /// what the dynamic providers answer to.
    case value

    /// Whether one candidate category can ever be written at this site.
    ///
    /// Static completion and module-owned live completion both feed the same
    /// bounded set. Keeping the gate on the subject means a provider cannot
    /// accidentally put a path, literal, or command in a member popup merely
    /// because it was handed that set.
    public func accepts(_ kind: ShellCompletionKind) -> Bool {
        switch self {
            case .none:
                return false
            case .receiverOrCommand:
                return kind == .namespace || kind == .command || kind == .variable
                    || kind == .keyword
            case .command:
                return kind == .command
            case .label:
                return kind == .label
            case .member:
                return kind == .member || kind == .method
            case .value:
                // Scoped expressions such as `$0.name` retain the role of
                // their final member, while symbol-valued parameters may ask
                // for names from the catalog.
                return kind == .variable || kind == .keyword || kind == .operatorSymbol
                    || kind == .path || kind == .namespace || kind == .command
                    || kind == .member || kind == .method
        }
    }
}

/// Everything a completer needs, decided once, where the language was read.
public struct ShellCompletionContext: Equatable {
    public let subject : ShellCompletionSubject

    /// The bytes already typed of the thing being completed. Empty when the
    /// cursor sits in open space, which is a request for everything that fits.
    public let start   : UInt16
    public let count   : UInt16

    /// The receiver written before the cursor, as a catalog index, or -1.
    public let receiver: Int

    /// The command whose call the cursor is inside, as a catalog index, or -1.
    public let command : Int

    /// Which of that command's arguments is being written.
    public let argument: Int

    /// The type that would fit here, when the command says so.
    public let expected: ShellValueType

    /// The shape of the value the cursor is reaching into, for `.member`.
    public let schema  : ShellTypeSchema

    /// What `$0` is in the closure surrounding the cursor, or nothing outside
    /// one. Kept separate from `schema`: before a closure has an answer, its
    /// element is still known even though its result is not.
    public let scope   : ShellTypeSchema
    public let scopeCount: UInt8
    private let scopeNameStart: UInt16
    private let scopeNameCount: UInt16

    /// The name a closure gave its first value, when it did. Stored compactly
    /// so one analysis snapshot stays inside its freestanding stack budget.
    public var scopeName: Span? {
        scopeNameCount == 0
            ? nil
            : Span(start: Int(scopeNameStart), count: Int(scopeNameCount))
    }

    public init(
        subject : ShellCompletionSubject = .none,
        start   : UInt16 = 0,
        count   : UInt16 = 0,
        receiver: Int = -1,
        command : Int = -1,
        argument: Int = 0,
        expected: ShellValueType = .any,
        schema  : ShellTypeSchema = .none,
        scope   : ShellTypeSchema = .none,
        scopeCount: UInt8 = 0,
        scopeName: Span? = nil
    ) {
        self.subject = subject
        self.start = start
        self.count = count
        self.receiver = receiver
        self.command = command
        self.argument = argument
        self.expected = expected
        self.schema = schema
        self.scope = scope
        self.scopeCount = scopeCount
        self.scopeNameStart = UInt16(clamping: scopeName?.start ?? 0)
        self.scopeNameCount = UInt16(clamping: scopeName?.count ?? 0)
    }

    public var prefix: Span { Span(start: Int(start), count: Int(count)) }
}
