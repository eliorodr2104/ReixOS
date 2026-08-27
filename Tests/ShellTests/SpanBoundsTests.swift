//
//  SpanBoundsTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ShellLanguage

/// Whether a span is a stretch of the line it claims to point into.
///
/// A `Span` is two integers and nothing else: it does not carry the buffer, and
/// it is handed around by a parser, stored in a `Command`, and eventually turned
/// into a pointer. So the one moment that matters is the moment before that
/// arithmetic, and the shell had no such moment. `line + span.start` was written
/// wherever a name was needed, and every one of those was a read wherever the
/// span said.
///
/// Nothing here is about a hostile line: the line is typed by the person at the
/// keyboard. It is about a span that does not come from the line at all - a
/// parser that returns a count it never checked, a module that keeps a span
/// across two lines, a length that came back from somewhere else. A shell that
/// dies on one of those is a shell that cannot be trusted with the next one.
@Suite("Span bounds")
struct SpanBoundsTests {

    @Test("a span inside the line is inside the line")
    func theOrdinaryCase() {
        #expect(Span(start: 0, count: 0).isInside(0))
        #expect(Span(start: 0, count: 8).isInside(8))
        #expect(Span(start: 3, count: 5).isInside(8))

        // The empty span at the very end: nothing to read, and nothing wrong
        // with pointing there. A parser hands one back for a receiver that was
        // left out, so refusing it would refuse `help`.
        #expect(Span(start: 8, count: 0).isInside(8))
    }


    @Test("a span reaching past the end is refused")
    func pastTheEnd() {
        #expect(!Span(start: 0, count: 9).isInside(8))
        #expect(!Span(start: 8, count: 1).isInside(8))
        #expect(!Span(start: 9, count: 0).isInside(8))
        #expect(!Span(start: 1, count: 8).isInside(8))

        // And an empty line holds nothing at all.
        #expect(!Span(start: 0, count: 1).isInside(0))
        #expect(!Span(start: 1, count: 0).isInside(0))
    }


    @Test("a negative start or count is refused rather than trapped on")
    func negatives() {
        #expect(!Span(start: -1, count: 0).isInside(8))
        #expect(!Span(start: -1, count: 4).isInside(8))
        #expect(!Span(start: 0, count: -1).isInside(8))
        #expect(!Span(start: 4, count: -4).isInside(8))
        #expect(!Span(start: -8, count: 8).isInside(8))

        // A negative count is the one that looks harmless: `count <= lineCount`
        // is true of it, and a loop written `0..<count` does nothing. It is the
        // pointer that is wrong - `line + start` with a start behind the buffer
        // reads memory this process was never given.
        #expect(!Span(start: -1, count: -1).isInside(8))
    }


    @Test("a sum that would overflow is refused, and does not trap on the way")
    func overflow() {
        // `start + count <= lineCount` is the obvious way to write the check and
        // the wrong one: this pair overflows the sum, and in Swift an overflow
        // is a trap, so the check would kill the shell instead of refusing the
        // span. Written as a subtraction there is nothing to overflow.
        #expect(!Span(start: Int.max, count: Int.max).isInside(8))
        #expect(!Span(start: Int.max, count: 1).isInside(8))
        #expect(!Span(start: 1, count: Int.max).isInside(8))
        #expect(!Span(start: Int.max - 4, count: 8).isInside(8))

        #expect(!Span(start: Int.min, count: 0).isInside(8))
        #expect(!Span(start: 0, count: Int.min).isInside(8))
        #expect(!Span(start: Int.min, count: Int.min).isInside(8))

        // Nor does a line of an impossible length let anything through.
        #expect(!Span(start: 0, count: 1).isInside(-1))
        #expect(!Span(start: 0, count: 0).isInside(-1))
        #expect(!Span(start: 4, count: 4).isInside(Int.min))
    }


    @Test("a line of no length, or less, is not parsed")
    func negativeLineCount() {
        // The parser is handed a count by whoever read the line. A terminal
        // that answers -1 for "gone" is the obvious source, and reading a line
        // of minus one byte is a walk backwards through memory.
        var byte = UInt8(ascii: "x")

        let refused = withUnsafePointer(to: &byte) { pointer in
            CommandParser.parse(pointer, count: -1)
        }

        guard case .failure(let failure) = refused else {
            Issue.record("a line of minus one byte was parsed")
            return
        }
        #expect(failure.reason == .notALine)
        #expect(failure.column == 0)

        let far = withUnsafePointer(to: &byte) { pointer in
            CommandParser.parse(pointer, count: Int.min)
        }
        guard case .failure(let low) = far else {
            Issue.record("a line of the least possible length was parsed")
            return
        }
        #expect(low.reason == .notALine)

        // Zero is not the same mistake: nothing was typed, which the shell
        // passes over in silence.
        let nothing = withUnsafePointer(to: &byte) { pointer in
            CommandParser.parse(pointer, count: 0)
        }
        guard case .failure(let empty) = nothing else {
            Issue.record("an empty line was parsed")
            return
        }
        #expect(empty.reason == .empty)
    }


    @Test("a path is not taken apart from a span outside the line")
    func pathSpansAreChecked() {
        // The line is eight bytes. Every span below either starts outside it,
        // reaches past it, or is a pair of numbers no line could hold, and each
        // one of them used to be a read: the parser took `span.start` and
        // `span.count` on trust because it was never handed the length.
        let bytes = Array("reix::ap".utf8)

        let outside = [
            Span(start: 0, count: 9),
            Span(start: 4, count: 8),
            Span(start: 9, count: 0),
            Span(start: 8, count: 1),
            Span(start: -1, count: 4),
            Span(start: 0, count: -1),
            Span(start: -1, count: -1),
            Span(start: Int.max, count: Int.max),
            Span(start: 1, count: Int.max),
            Span(start: Int.min, count: 0),
        ]

        bytes.withUnsafeBufferPointer { buffer in
            for span in outside {
                let taken = PathParser.parse(
                    buffer.baseAddress!, count: buffer.count, span: span
                )

                guard case .failure(.notALine) = taken else {
                    Issue.record(
                        "a span of (\(span.start), \(span.count)) was taken apart"
                    )
                    continue
                }
            }

            // And a line of an impossible length holds no span at all, not even
            // the empty one: a reader answering -1 is the source of that count.
            guard case .failure(.notALine) = PathParser.parse(
                buffer.baseAddress!, count: -1, span: Span(start: 0, count: 0)
            ) else {
                Issue.record("a path was read out of a line of minus one byte")
                return
            }

            // The stretch that really is the line still parses, so the check
            // refuses what is outside rather than everything.
            guard case .success(let parts) = PathParser.parse(
                buffer.baseAddress!, count: buffer.count,
                span: Span(start: 0, count: buffer.count)
            ) else {
                Issue.record("a path that is a stretch of the line was refused")
                return
            }
            #expect(parts.isRooted)
            #expect(parts.containerCount == 1)
        }
    }


    @Test("every span a parse hands back is inside the line it parsed")
    func parsedSpansAreInside() {
        let lines = [
            "shell.help",
            "shell.help()",
            "help",
            "fs.write a.txt \"hello there\"",
            "fs.move(reix::app::child/doc/file.txt)",
            "disk.read 0",
            "process.spawn(\"Top.elf\")",
            "fs.container app 64",
            "a.b c, d, e, f",
        ]

        for line in lines {
            let bytes = Array(line.utf8)

            bytes.withUnsafeBufferPointer { buffer in
                guard case .success(let command) = CommandParser.parse(
                    buffer.baseAddress!, count: buffer.count
                ) else {
                    Issue.record("a well-formed line was refused: \(line)")
                    return
                }

                #expect(command.receiver.isInside(buffer.count), "receiver of \(line)")
                #expect(command.verb.isInside(buffer.count), "verb of \(line)")

                for index in 0..<command.argumentCount {
                    #expect(
                        command.arguments[index].isInside(buffer.count),
                        "argument \(index) of \(line)"
                    )
                }
            }
        }
    }
}
