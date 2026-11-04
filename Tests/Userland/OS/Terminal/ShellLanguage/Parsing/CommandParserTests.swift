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

    private func text(
        _ span     : Span,
          of source: String
    ) -> String {
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
        let line = "process.spawn(\"Top.elf\")"

        guard case .success(let command) = parse(line) else {
            Issue.record("a well-formed line was refused")
            return
        }

        #expect(text(command.verb, of: line) == "spawn")
        #expect(command.argumentCount == 1)
        #expect(text(command.arguments[0], of: line) == "Top.elf")
    }


    @Test("a bare argument is any printable run with no space in it")
    func bareArgument() {
        for line in ["disk.read(0)", "disk.read 0"] {
            guard case .success(let command) = parse(line) else {
                Issue.record("a bare argument was refused")
                return
            }

            #expect(text(command.verb, of: line) == "read")
            #expect(command.argumentCount == 1)
            #expect(text(command.arguments[0], of: line) == "0")
        }

        // Slashes, colons and dots are ordinary characters in an argument,
        // which is the whole reason quotes stopped being required.
        let path = "fs.move(reix::app::child/doc/file.txt)"
        guard case .success(let moved) = parse(path) else {
            Issue.record("a path argument was refused")
            return
        }
        #expect(text(moved.arguments[0], of: path) == "reix::app::child/doc/file.txt")

        // A space still has to be quoted: a space is what ends an argument.
        let spaced = "fs.write(\"a.txt\", \"two words\")"
        guard case .success(let written) = parse(spaced) else {
            Issue.record("a quoted argument with a space was refused")
            return
        }
        #expect(written.argumentCount == 2)
        #expect(text(written.arguments[1], of: spaced) == "two words")
    }


    @Test("the same command written four ways parses the same four times")
    func fourWaysOfWritingIt() {
        let lines = [
            "fs.move(\"reix::app/doc/x.txt\")",
            "move(\"reix::app/doc/x.txt\")",
            "move \"reix::app/doc/x.txt\"",
            "move reix::app/doc/x.txt"
        ]

        for line in lines {
            guard case .success(let command) = parse(line) else {
                Issue.record("this way of writing it was refused")
                return
            }

            #expect(text(command.verb, of: line) == "move")
            #expect(command.argumentCount == 1)
            #expect(text(command.arguments[0], of: line) == "reix::app/doc/x.txt")
        }

        // And the receiver is there when it was written and absent when it was
        // not, because which of the two it is stays the shell's business.
        guard case .success(let named) = parse(lines[0]),
              case .success(let bare)  = parse(lines[3])
        else { return }

        #expect(text(named.receiver, of: lines[0]) == "fs")
        #expect(bare.receiver.count == 0)
    }


    @Test("arguments without parentheses may be separated by spaces or commas")
    func spaceSeparatedArguments() {
        for line in ["fs.write a.txt hello", "fs.write a.txt, hello"] {
            guard case .success(let command) = parse(line) else {
                Issue.record("space-separated arguments were refused")
                return
            }

            #expect(command.argumentCount == 2)
            #expect(text(command.arguments[0], of: line) == "a.txt")
            #expect(text(command.arguments[1], of: line) == "hello")
        }
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
            // A space where a dot was meant. It used to be caught as two names
            // with nothing joining them; now a space joins a verb to its
            // arguments, so `shell help` is a command and it is the bracket
            // after it that has nowhere to go. The price of writing paths
            // without quotes, paid here.
            ("shell help()",          .expectedArgument,        10),
            ("shell.",                .expectedName,             6),
            ("process.spawn(",        .expectedArgument,        14),
            ("process.spawn(,)",     .expectedArgument,        14),
            ("process.spawn(\"a",     .unterminatedText,        16),
            ("process.spawn(\"a\"",   .expectedCloseParenthesis, 17),
            ("shell.help() x",        .trailingCharacters,      13),
            // Without parentheses too: a quote that never closes is its own
            // mistake and keeps its own name.
            ("move \"a",               .unterminatedText,         7),
            // A quote inside a bare word ends the word and starts a text,
            // which then never closes.
            ("move a\"b",              .unterminatedText,         8),
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
        let line = "spawn(\"Top.elf\")"

        guard case .success(let command) = parse(line) else {
            Issue.record("a bare verb with an argument was refused")
            return
        }

        #expect(command.receiver.count == 0)
        #expect(text(command.verb, of: line) == "spawn")
        #expect(command.argumentCount == 1)
        #expect(text(command.arguments[0], of: line) == "Top.elf")
    }


    @Test("what follows a bare verb is arguments, and what follows a call is not")
    func afterTheVerb() {
        // Without parentheses, what comes next is an argument. This used to be
        // a parse error, and stopped being one when paths had to be writable
        // without quotes.
        guard case .success(let command) = parse("help extra") else {
            Issue.record("a bare verb with an argument was refused")
            return
        }
        #expect(command.argumentCount == 1)

        // With them, the call is finished and anything after it is not.
        guard case .failure(let trailing) = parse("process.list()junk") else {
            Issue.record("junk after a call parsed as a command")
            return
        }
        #expect(trailing.reason == .trailingCharacters)

        // And a lone bracket is not an argument.
        guard case .failure(let bracket) = parse("help)") else {
            Issue.record("a stray bracket parsed as an argument")
            return
        }
        #expect(bracket.reason == .expectedArgument)
    }
}
