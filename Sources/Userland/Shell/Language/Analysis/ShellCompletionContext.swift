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

    /// The type that would fit here, when the command says so.
    public let expected: ShellValueType

    /// The shape of the value the cursor is reaching into, for `.member`.
    public let schema  : ShellTypeSchema

    public init(
        subject : ShellCompletionSubject = .none,
        start   : UInt16 = 0,
        count   : UInt16 = 0,
        receiver: Int = -1,
        command : Int = -1,
        expected: ShellValueType = .any,
        schema  : ShellTypeSchema = .none
    ) {
        self.subject = subject
        self.start = start
        self.count = count
        self.receiver = receiver
        self.command = command
        self.expected = expected
        self.schema = schema
    }

    public var prefix: Span { Span(start: Int(start), count: Int(count)) }
}
