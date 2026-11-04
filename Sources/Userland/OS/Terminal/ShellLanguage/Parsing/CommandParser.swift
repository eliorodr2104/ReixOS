//
//  CommandParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// The grammar of the shell, which is a deliberate subset of Swift's own:
///
///     ( receiver '.' )? verb ( '(' args? ')' | ' ' args )?
///     args := argument ( ( ',' | ' ' ) argument )*
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
/// An argument is a quoted text or a bare run of printable characters with no
/// space, comma, quote or parenthesis in it. Quotes were once required, on the
/// reasoning that a mistyped name should not quietly become an argument. Paths
/// changed that: `move reix::app::child/doc/file.txt` is how a path is written,
/// and making people quote it would make the shell's syntax a thing to remember
/// rather than a thing to recognise. Quotes are still what carries a space.
///
/// The parentheses and the commas are optional together with them: `move x`,
/// `move("x")` and `fs.move "x"` are one command written three ways, which is
/// the point. Nesting and pipelines are absent rather than half-built: both
/// want a value model the system does not carry between processes yet.
public enum CommandParser {

    public static func parse(
        _ line: UnsafePointer<UInt8>,
          count : Int
    ) -> Result<Command, ParseFailure> {

        // A length of less than nothing is not a short line, it is not a line.
        // The obvious source is a reader answering -1 for "the terminal is
        // gone": every loop below is written `cursor < count` and would simply
        // fall through, handing back spans that point outside the buffer.
        guard count >= 0 else {
            return .failure(ParseFailure(reason: .notALine, column: 0))
        }

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

        // Nothing after the verb at all.
        guard cursor < count else { return .success(command) }

        // Parentheses that would hold nothing may be left off entirely, and so
        // may the parentheses that would hold something.
        guard line[cursor] == Self.openParenthesis else {
            while cursor < count {
                let text: Span

                switch argument(line, from: &cursor, count: count) {
                    case .text(let span) : text = span
                    case .unterminated   : return .failure(ParseFailure(reason: .unterminatedText, column: cursor))
                    case .missing        : return .failure(ParseFailure(reason: .expectedArgument, column: cursor))
                }

                guard command.argumentCount < command.arguments.count else {
                    return .failure(ParseFailure(reason: .tooManyArguments, column: cursor))
                }

                command.arguments[command.argumentCount] = text
                command.argumentCount += 1

                cursor = skipSpaces(line, from: cursor, count: count)

                // A comma between them is allowed and means nothing: the space
                // already separated them.
                if cursor < count, line[cursor] == Self.comma {
                    cursor += 1
                    cursor = skipSpaces(line, from: cursor, count: count)
                }
            }

            return .success(command)
        }
        cursor += 1

        cursor = skipSpaces(line, from: cursor, count: count)

        if cursor < count, line[cursor] == Self.closeParenthesis {
            cursor += 1

        } else {
            while true {
                let text: Span

                switch argument(line, from: &cursor, count: count) {
                    case .text(let span) : text = span
                    case .unterminated   : return .failure(ParseFailure(reason: .unterminatedText, column: cursor))
                    case .missing        : return .failure(ParseFailure(reason: .expectedArgument, column: cursor))
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


    /// What reading one argument produced.
    ///
    /// Three outcomes and not two, because a quote that never closes is a
    /// different mistake from an argument that was never there, and the caret
    /// in the error should say which.
    private enum Argument {
        case text(Span)
        case missing
        case unterminated
    }


    /// One argument: a quoted text, or a bare run of printable characters.
    private static func argument(
        _ line: UnsafePointer<UInt8>,
        from cursor: inout Int,
        count : Int
    ) -> Argument {

        if cursor < count, line[cursor] == Self.quote {
            guard let quoted = quotedText(line, from: &cursor, count: count) else {
                return .unterminated
            }
            return .text(quoted)
        }

        let start = cursor
        while cursor < count, isArgumentByte(line[cursor]) { cursor += 1 }

        guard cursor > start else { return .missing }

        return .text(Span(start: start, count: cursor - start))
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
        isNameStart(byte) || isDigit(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// What may appear in a bare argument: anything printable that is not a
    /// separator of the grammar itself.
    ///
    /// Which is to say `/`, `:`, `.` and `-` are ordinary characters here, and
    /// a path is written the way it is written. A space still has to be quoted,
    /// because a space is what separates one argument from the next.
    private static func isArgumentByte(_ byte: UInt8) -> Bool {
        byte > Self.space
        && byte < 0x7F
        && byte != Self.comma
        && byte != Self.quote
        && byte != Self.openParenthesis
        && byte != Self.closeParenthesis
    }

    private static let space           : UInt8 = 0x20
    private static let dot             : UInt8 = 0x2E
    private static let comma           : UInt8 = 0x2C
    private static let quote           : UInt8 = 0x22
    private static let openParenthesis : UInt8 = 0x28
    private static let closeParenthesis: UInt8 = 0x29
    private static let underscore      : UInt8 = 0x5F
}
