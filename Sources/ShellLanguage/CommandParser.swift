//
//  CommandParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// A stretch of the typed line, by offset and length.
///
/// Nothing is copied out of the line buffer, here or anywhere below: the parse
/// hands back where things are, and the caller reads them in place. That is not
/// only about allocation, it is what lets an error point at a column.
public struct Span {
    public let start: Int
    public let count: Int

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }
}


/// One parsed command: `receiver.verb(arguments)`.
public struct Command {
    public let receiver : Span
    public let verb     : Span
    public var arguments: InlineArray<4, Span> = InlineArray(repeating: Span(start: 0, count: 0))
    public var argumentCount: Int = 0
}


/// Why a line was refused, and where.
///
/// The column travels with the reason so the shell can point at the character
/// that broke, rather than answering "syntax error" and leaving the reader to
/// find it. A terminal with no cursor addressing can still draw a caret under
/// the right column.
public struct ParseFailure: Error {
    public let reason: Reason
    public let column: Int

    public enum Reason: Equatable {
        case empty
        case expectedName
        case expectedOpenParenthesis
        case expectedCloseParenthesis
        case expectedArgument
        case unterminatedText
        case tooManyArguments
        case trailingCharacters
    }

    public var message: StaticString {
        switch reason {
            case .empty                    : "nothing to run"
            case .expectedName             : "expected a name"
            case .expectedOpenParenthesis  : "expected '(' after the verb"
            case .expectedCloseParenthesis : "expected ')'"
            case .expectedArgument         : "expected a quoted argument"
            case .unterminatedText         : "this text is missing its closing quote"
            case .tooManyArguments         : "too many arguments"
            case .trailingCharacters       : "unexpected characters after ')'"
        }
    }
}


/// The grammar of the shell, which is a deliberate subset of Swift's own:
///
///     ( receiver '.' )? verb ( '(' ( text ( ',' text )* )? ')' )?
///
/// Small enough to be written by hand and honest about what it will become. The
/// receiver is not decoration: it names the authority the shell is acting
/// through, so `process.spawn` reads as what it is, a use of a capability this
/// process holds, and a receiver the shell has no capability for simply does not
/// answer. That is the whole reason the syntax is shaped this way rather than
/// as a list of bare verbs.
///
/// Both halves around the verb are optional, and for the same reason Swift lets
/// them go: parentheses that would hold nothing say nothing, and a receiver that
/// could only be one thing is noise. `process.spawn("Top.elf")`, `process.list`
/// and `help` are all this grammar. What the receiver falls back to when it is
/// left out is the shell's business, not the parser's: an absent receiver comes
/// back as an empty span.
///
/// Arguments are quoted text only. Numbers, nesting and pipelines are absent
/// rather than half-built: each of them wants a value model the system does not
/// carry between processes yet.
public enum CommandParser {

    public static func parse(
        _ line: UnsafePointer<UInt8>,
        count : Int
    ) -> Result<Command, ParseFailure> {

        var cursor = skipSpaces(line, from: 0, count: count)

        guard cursor < count else {
            return .failure(ParseFailure(reason: .empty, column: cursor))
        }

        guard let first = name(line, from: &cursor, count: count) else {
            return .failure(ParseFailure(reason: .expectedName, column: cursor))
        }

        // A dot means the name just read was the receiver and the verb follows.
        // Without one the name is the verb and the receiver was left out.
        var receiver = Span(start: cursor, count: 0)
        var verb     = first

        if cursor < count, line[cursor] == Self.dot {
            cursor += 1

            guard let named = name(line, from: &cursor, count: count) else {
                return .failure(ParseFailure(reason: .expectedName, column: cursor))
            }

            receiver = first
            verb     = named
        }

        var command = Command(receiver: receiver, verb: verb)

        cursor = skipSpaces(line, from: cursor, count: count)

        // Parentheses that would hold nothing may be left off entirely.
        guard cursor < count, line[cursor] == Self.openParenthesis else {
            guard cursor == count else {
                return .failure(ParseFailure(reason: .trailingCharacters, column: cursor))
            }

            return .success(command)
        }
        cursor += 1

        cursor = skipSpaces(line, from: cursor, count: count)

        if cursor < count, line[cursor] == Self.closeParenthesis {
            cursor += 1

        } else {
            while true {
                guard cursor < count, line[cursor] == Self.quote else {
                    return .failure(ParseFailure(reason: .expectedArgument, column: cursor))
                }

                guard let text = quotedText(line, from: &cursor, count: count) else {
                    return .failure(ParseFailure(reason: .unterminatedText, column: cursor))
                }

                guard command.argumentCount < command.arguments.count else {
                    return .failure(ParseFailure(reason: .tooManyArguments, column: cursor))
                }

                command.arguments[command.argumentCount] = text
                command.argumentCount += 1

                cursor = skipSpaces(line, from: cursor, count: count)

                guard cursor < count else {
                    return .failure(ParseFailure(reason: .expectedCloseParenthesis, column: cursor))
                }

                if line[cursor] == Self.comma {
                    cursor += 1
                    cursor = skipSpaces(line, from: cursor, count: count)
                    continue
                }

                guard line[cursor] == Self.closeParenthesis else {
                    return .failure(ParseFailure(reason: .expectedCloseParenthesis, column: cursor))
                }

                cursor += 1
                break
            }
        }

        cursor = skipSpaces(line, from: cursor, count: count)

        guard cursor == count else {
            return .failure(ParseFailure(reason: .trailingCharacters, column: cursor))
        }

        return .success(command)
    }


    /// A Swift identifier: a letter or underscore, then letters, digits and
    /// underscores. `nil` without moving the cursor when there is none.
    private static func name(
        _ line: UnsafePointer<UInt8>,
        from cursor: inout Int,
        count : Int
    ) -> Span? {
        let start = cursor

        guard cursor < count, isNameStart(line[cursor]) else { return nil }
        cursor += 1

        while cursor < count, isNameBody(line[cursor]) { cursor += 1 }

        return Span(start: start, count: cursor - start)
    }


    /// The inside of a pair of quotes, cursor left past the closing one. No
    /// escapes: a quote ends the text, and there is nothing a path needs that
    /// this refuses.
    private static func quotedText(
        _ line: UnsafePointer<UInt8>,
        from cursor: inout Int,
        count : Int
    ) -> Span? {
        cursor += 1 // the opening quote
        let start = cursor

        while cursor < count, line[cursor] != Self.quote { cursor += 1 }

        guard cursor < count else { return nil }

        let text = Span(start: start, count: cursor - start)
        cursor += 1 // the closing quote

        return text
    }


    private static func skipSpaces(
        _ line: UnsafePointer<UInt8>,
        from  : Int,
        count : Int
    ) -> Int {
        var cursor = from
        while cursor < count, line[cursor] == Self.space { cursor += 1 }

        return cursor
    }


    private static func isNameStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A)   // A-Z
        || (byte >= 0x61 && byte <= 0x7A) // a-z
        || byte == Self.underscore
    }

    private static func isNameBody(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (byte >= 0x30 && byte <= 0x39) // 0-9
    }

    private static let space            : UInt8 = 0x20
    private static let dot              : UInt8 = 0x2E
    private static let comma            : UInt8 = 0x2C
    private static let quote            : UInt8 = 0x22
    private static let openParenthesis  : UInt8 = 0x28
    private static let closeParenthesis : UInt8 = 0x29
    private static let underscore       : UInt8 = 0x5F
}
