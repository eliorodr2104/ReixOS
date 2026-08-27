//
//  ShellEngineTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ShellLanguage

/// The shell's loop, without a terminal and without a module.
///
/// What is being tested is the shape of one turn: what a count means, what a
/// refusal is passed over and what is reported, and above all that `exit` is
/// final. That last one is the reason this suite exists at all - the rule lived
/// in a `while` around a global inside `_start`, so the only way to find out
/// whether a stopped shell reads another line was to boot a machine and type.
///
/// `carryOut` is the seam the modules go through. Here it is a closure that
/// records every command it was handed, so "nothing was interpreted" is a count
/// of zero rather than an absence of output.
@Suite("Shell engine")
struct ShellEngineTests {

    /// What the dispatch was handed, so that "nothing was interpreted" is a
    /// count of zero rather than an absence of output.
    ///
    /// A class because the closure has to write into it while the engine holds
    /// it, and a struct captured by a closure passed to a mutating method is an
    /// exclusivity violation rather than a recording.
    private final class Dispatched {
        var count    = 0
        var receiver = ""
        var verb     = ""
    }

    /// Runs one line through `engine` and reports what the dispatch saw.
    ///
    /// `answer` is what the module would have returned, so a test picks
    /// `.exitRequested` without needing a module that asks to exit.
    private func step(
        _ engine: inout ShellEngine,
        _ text  : String,
          count   : Int? = nil,
          answer  : ShellOutcome = .handled,
          seen    : Dispatched
    ) -> ShellEngine.Step {

        let bytes = Array(text.utf8)
        let given = count ?? bytes.count

        // A byte to point at even when the line is empty or the count is a
        // reader's -1, so that the engine's refusal is a refusal to read.
        var spare = UInt8(ascii: " ")

        return bytes.isEmpty
            ? withUnsafeMutablePointer(to: &spare) { pointer in
                engine.step(pointer, count: given) { command in
                    record(command, text: bytes, into: seen)
                    return answer
                }
            }
            : bytes.withUnsafeBufferPointer { buffer in
                engine.step(buffer.baseAddress!, count: given) { command in
                    record(command, text: bytes, into: seen)
                    return answer
                }
            }
    }

    private func record(
        _ command  : Command,
          text     : [UInt8],
          into seen: Dispatched
    ) {
        seen.count += 1
        seen.receiver = word(command.receiver, of: text)
        seen.verb     = word(command.verb, of: text)
    }

    private func word(
        _ span   : Span,
          of text: [UInt8]
    ) -> String {
        guard span.isInside(text.count) else { return "<outside>" }

        return String(decoding: text[span.start ..< span.start + span.count], as: UTF8.self)
    }


    @Test("a command is parsed once and handed to the dispatch")
    func aCommandIsCarriedOut() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        let step = step(&engine, "process.list()", seen: seen)

        #expect(step == .carriedOut)
        #expect(engine.reading)
        #expect(seen.count == 1)
        #expect(seen.receiver == "process")
        #expect(seen.verb == "list")
    }


    @Test("an outcome that does not stop the shell leaves it reading")
    func outcomesThatDoNotStop() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        #expect(step(&engine, "help", answer: .handled, seen: seen) == .carriedOut)
        #expect(engine.reading)

        // `notHandled` means no module wanted it, which the shell says something
        // about and then goes on. It is not a reason to stop reading.
        #expect(step(&engine, "wat", answer: .notHandled, seen: seen) == .carriedOut)
        #expect(engine.reading)

        #expect(seen.count == 2)
    }


    @Test("nothing typed is passed over in silence")
    func blankLines() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        // Zero bytes: the reader saw a bare newline.
        #expect(step(&engine, "", seen: seen) == .blank)

        // A line of nothing but spaces is `.empty` to the parser, and a blank
        // line here rather than a mistake to point a caret at.
        #expect(step(&engine, "    ", seen: seen) == .blank)

        #expect(engine.reading)
        #expect(seen.count == 0)
    }


    /// A line of tabs is refused for wanting a name, not passed over as blank.
    ///
    /// `skipSpaces` knows one byte, 0x20. Written down rather than fixed here
    /// because the editor in the terminal server accepts only 0x20 through 0x7E:
    /// a tab never reaches this parser from a keyboard, and widening the grammar
    /// for a byte nothing can type is a change to the language rather than a
    /// closing of the loop.
    ///
    /// If that editor ever passes control bytes through, this is the test that
    /// says the parser has to be taught about them first.
    @Test("a tab is not a space, and the terminal is why that is not a bug")
    func tabsAreNotSpaces() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        guard case .refused(let failure) = step(&engine, "\t \t", seen: seen) else {
            Issue.record("a line of tabs was taken for a blank one")
            return
        }
        #expect(failure.reason == .expectedName)
        #expect(failure.column == 0)
        #expect(seen.count == 0)
        #expect(engine.reading)
    }


    @Test("a line that is not a command is refused, with the column")
    func refusals() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        guard case .refused(let failure) = step(&engine, "shell.", seen: seen) else {
            Issue.record("a line ending in a dot was accepted")
            return
        }
        #expect(failure.reason == .expectedName)

        guard case .refused(let unclosed) = step(&engine, "fs.write(\"a", seen: seen)
        else {
            Issue.record("an unterminated text was accepted")
            return
        }
        #expect(unclosed.reason == .unterminatedText)

        // A refusal is not a reason to stop, and nothing was dispatched.
        #expect(engine.reading)
        #expect(seen.count == 0)
    }


    @Test("the caret lands under the column the parser named")
    func theCaretIsUnderThePrompt() {
        let engine = ShellEngine(capacity: 128)

        // The line is echoed after the prompt, so column zero is the first byte
        // typed and sits directly after it.
        #expect(ShellEngine.prompt.utf8CodeUnitCount == 6)
        #expect(engine.caret(under: 0) == 6)
        #expect(engine.caret(under: 7) == 13)
        #expect(engine.caret(under: 128) == 134)

        // A column no line of this length could hold is nobody's typing. Pointed
        // at the start: the shell writes that many spaces one at a time, so a
        // large one is a hang and `Int.max` is an overflow trap in the reporting.
        #expect(engine.caret(under: -1) == 6)
        #expect(engine.caret(under: Int.min) == 6)
        #expect(engine.caret(under: 129) == 6)
        #expect(engine.caret(under: Int.max) == 6)
    }


    @Test("a reader that is gone stops the shell")
    func readerGone() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        #expect(step(&engine, "", count: -1, seen: seen) == .readerGone)
        #expect(!engine.reading)
        #expect(seen.count == 0)
    }


    @Test("a count past the line buffer is refused rather than parsed")
    func overrun() {
        var engine = ShellEngine(capacity: 16)
        let seen   = Dispatched()

        // Seventeen into sixteen is not a long line, it is a reader answering
        // about a different buffer, and parsing it walks off the end of this one.
        #expect(step(&engine, "help", count: 17, seen: seen) == .overrun(17))
        #expect(!engine.reading)
        #expect(seen.count == 0)

        // Exactly the capacity is a full line and not an overrun.
        var full = ShellEngine(capacity: 4)
        #expect(step(&full, "help", count: 4, seen: seen) == .carriedOut)
        #expect(full.reading)
    }


    @Test("after exit nothing more is read, parsed or carried out")
    func exitIsFinal() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        #expect(step(&engine, "shell.exit()", answer: .exitRequested, seen: seen)
                == .finished)
        #expect(!engine.reading)
        #expect(seen.count == 1)

        // Each of these is `closed`, which is the engine saying it did not look:
        // a stopped engine that still parsed would answer `.refused` and `.blank`.
        #expect(step(&engine, "process.list()", seen: seen) == .closed)
        #expect(step(&engine, "shell.", seen: seen) == .closed)
        #expect(step(&engine, "", seen: seen) == .closed)
        #expect(step(&engine, "    ", seen: seen) == .closed)
        #expect(step(&engine, "", count: -1, seen: seen) == .closed)
        #expect(step(&engine, "help", count: 9999, seen: seen) == .closed)

        #expect(seen.count == 1)
        #expect(!engine.reading)
    }


    @Test("a later outcome cannot talk a stopped shell out of stopping")
    func stoppingIsNotUndone() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        #expect(step(&engine, "shell.exit()", answer: .exitRequested, seen: seen)
                == .finished)

        // `.handled` would be `running = !stops` written the obvious wrong way,
        // and this is the line that would flip it back.
        #expect(step(&engine, "help", answer: .handled, seen: seen) == .closed)
        #expect(!engine.reading)
        #expect(seen.count == 1)
    }


    @Test("the shell that was never asked to stop keeps reading")
    func theLoopEndsForOneReasonOnly() {
        var engine = ShellEngine(capacity: 128)
        let seen   = Dispatched()

        // Twenty turns of everything that is not an exit and not a dead reader.
        for turn in 0..<20 {
            let step = switch turn % 4 {
                case 0: step(&engine, "help", seen: seen)
                case 1: step(&engine, "", seen: seen)
                case 2: step(&engine, "shell.", seen: seen)
                default: step(&engine, "disk.list()", answer: .notHandled, seen: seen)
            }

            #expect(step != .closed)
            #expect(engine.reading)
        }

        #expect(engine.reading)
    }
}
