//
//  CommandParserTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
import ShellLanguage

/// The shell's grammar: `receiver.verb(arguments)`.
///
/// Worth a suite of its own because it is the one part of a terminal that is
/// pure logic, and because the column an error carries is not decoration: it is
/// what puts the caret under the character that broke.
@Suite("Command parser")
struct CommandParserTests {

    private func parse(_ text: String) -> Result<Command, ParseFailure> {
        let bytes = Array(text.utf8)

        return bytes.withUnsafeBufferPointer { buffer in
            CommandParser.parse(buffer.baseAddress!, count: buffer.count)
        }
    }

    private func text(_ span: Span, of source: String) -> String {
        let bytes = Array(source.utf8)[span.start ..< (span.start + span.count)]

        return String(decoding: bytes, as: UTF8.self)
    }


    @Test("a verb with no arguments parses to a receiver and a verb")
    func noArguments() {
        let line = "shell.help()"

        guard case .success(let command) = parse(line) else {
            Issue.record("a well-formed line was refused")
            return
        }

        #expect(text(command.receiver, of: line) == "shell")
        #expect(text(command.verb,     of: line) == "help")
        #expect(command.argumentCount == 0)
    }


    @Test("a quoted argument comes back without its quotes")
    func oneArgument() {
        let line = "process.spawn(\"Hello.elf\")"

        guard case .success(let command) = parse(line) else {
            Issue.record("a well-formed line was refused")
            return
        }

        #expect(text(command.verb, of: line) == "spawn")
        #expect(command.argumentCount == 1)
        #expect(text(command.arguments[0], of: line) == "Hello.elf")
    }


    @Test("spaces anywhere they are harmless are harmless")
    func spacing() {
        let line = "   process . spawn ( \"a\" , \"b\" )   "

        // Deliberately not accepted: a space before the dot would make
        // `process` and `.spawn` two things, and this grammar has one shape.
        guard case .failure = parse(line) else {
            Issue.record("spaces around the dot should not be accepted")
            return
        }

        let tight = "process.spawn( \"a\" , \"b\" )   "

        guard case .success(let command) = parse(tight) else {
            Issue.record("spaces inside the parentheses should be accepted")
            return
        }

        #expect(command.argumentCount == 2)
        #expect(text(command.arguments[0], of: tight) == "a")
        #expect(text(command.arguments[1], of: tight) == "b")
    }


    @Test("an empty line is refused as empty, not as a syntax error")
    func emptyLine() {
        for line in ["", "    "] {
            guard case .failure(let failure) = parse(line) else {
                Issue.record("an empty line parsed as a command")
                return
            }

            // The shell tells these apart: nothing typed goes back to the
            // prompt in silence, everything else gets a caret and a reason.
            #expect(failure.reason == .empty)
        }
    }


    @Test("each malformed shape is refused for its own reason, at its own column")
    func failures() {
        let cases: [(line: String, reason: ParseFailure.Reason, column: Int)] = [
            ("1bad.help()",           .expectedName,             0),
            // Two names with nothing joining them: the first parses, and what
            // follows it is not part of any command.
            ("shell help()",          .trailingCharacters,       6),
            ("shell.",                .expectedName,             6),
            ("process.spawn(",        .expectedArgument,        14),
            ("process.spawn(a)",      .expectedArgument,        14),
            ("process.spawn(\"a",     .unterminatedText,        16),
            ("process.spawn(\"a\"",   .expectedCloseParenthesis, 17),
            ("shell.help() x",        .trailingCharacters,      13),
        ]

        for expected in cases {
            guard case .failure(let failure) = parse(expected.line) else {
                Issue.record("'\(expected.line)' parsed as a command")
                continue
            }

            #expect(failure.reason == expected.reason)
            #expect(failure.column == expected.column)
        }
    }


    @Test("more arguments than there is room for are refused, not dropped")
    func tooManyArguments() {
        let line = "a.b(\"1\",\"2\",\"3\",\"4\",\"5\")"

        guard case .failure(let failure) = parse(line) else {
            Issue.record("five arguments fitted into four slots")
            return
        }

        #expect(failure.reason == .tooManyArguments)
    }


    @Test("a name may hold digits and underscores after its first character")
    func identifierShape() {
        let line = "my_thing2.do_it3()"

        guard case .success(let command) = parse(line) else {
            Issue.record("a legal identifier was refused")
            return
        }

        #expect(text(command.receiver, of: line) == "my_thing2")
        #expect(text(command.verb,     of: line) == "do_it3")
    }
}


/// The short forms, which are the grammar dropping what it can do without.
extension CommandParserTests {

    @Test("empty parentheses may be left off")
    func parenthesesAreOptional() {
        let line = "process.list"

        guard case .success(let command) = parse(line) else {
            Issue.record("a verb without parentheses was refused")
            return
        }

        #expect(text(command.receiver, of: line) == "process")
        #expect(text(command.verb,     of: line) == "list")
        #expect(command.argumentCount == 0)
    }


    @Test("the receiver may be left off, and comes back as an empty span")
    func receiverIsOptional() {
        for line in ["help", "help()"] {
            guard case .success(let command) = parse(line) else {
                Issue.record("'\(line)' was refused")
                continue
            }

            // Which receiver an absent one means is the shell's decision, so the
            // parser says nothing about it beyond that there was none.
            #expect(command.receiver.count == 0)
            #expect(text(command.verb, of: line) == "help")
        }
    }


    @Test("a bare verb still takes arguments")
    func bareVerbWithArguments() {
        let line = "spawn(\"Hello.elf\")"

        guard case .success(let command) = parse(line) else {
            Issue.record("a bare verb with an argument was refused")
            return
        }

        #expect(command.receiver.count == 0)
        #expect(text(command.verb, of: line) == "spawn")
        #expect(command.argumentCount == 1)
        #expect(text(command.arguments[0], of: line) == "Hello.elf")
    }


    @Test("dropping the parentheses does not license anything after the verb")
    func nothingFollowsABareVerb() {
        for line in ["help extra", "process.list()junk", "help)"] {
            guard case .failure(let failure) = parse(line) else {
                Issue.record("'\(line)' parsed as a command")
                continue
            }

            #expect(failure.reason == .trailingCharacters)
        }
    }
}
