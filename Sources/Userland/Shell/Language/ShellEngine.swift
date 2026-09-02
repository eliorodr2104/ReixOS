//
//  ShellEngine.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// One turn of the shell's loop, with the terminal and the modules left out.
///
/// What was here before was a `while` in `_start` around a global `Bool`, and
/// that is a shape with nothing to hold on to: the loop, the reader, the parser,
/// the module registry and the decision to stop were one function in an
/// executable built against the syscall stubs, so none of it could be run from a
/// host suite. The rule that matters most in a shell - after `exit`, nothing more
/// is read and nothing more is interpreted - was three lines spread across two
/// files and asserted by nothing.
///
/// So the two things that are not the terminal and not a module live here. The
/// engine holds whether this shell still reads, and it answers what one line
/// came to. The loop keeps what only it can do: printing, and calling a reader.
/// `carryOut` is the seam - in the shell it is the module registry, in a test it
/// is a closure that records what it was asked and answers what the test wants.
///
/// Deliberately not here: printing. A step says what happened and the caller
/// says it out loud, because a step that printed would need a console to be
/// tested against and we are back where we started.
public struct ShellEngine {

    /// What the shell writes before each line it reads.
    ///
    /// Here and not in the executable because the caret under a parse failure is
    /// measured from it: the column the parser reports is an offset into the
    /// line, and the line was echoed after the prompt.
    public static let prompt: StaticString = "reix❯ "
    public static let promptColumns = 6

    /// How many spaces go before the caret that points at `column`.
    ///
    /// A column outside the line is pointed at the start of it. The shell writes
    /// this many spaces one at a time, so a column no line could have produced
    /// would be a hang rather than a caret in the wrong place, and adding to it
    /// unchecked would be an overflow trap in the code that reports a mistake.
    public func caret(under column: Int) -> Int {
        let width = Self.promptColumns

        guard column >= 0, column <= capacity else { return width }

        return column + width
    }


    /// What one turn came to.
    public enum Step: Equatable {

        /// The shell had already been asked to stop. Nothing was read, nothing
        /// was parsed, and `carryOut` was not called.
        case closed

        /// The reader answered a negative count, which is how it says it is
        /// gone. The shell stops: nothing it printed afterwards would be read.
        case readerGone

        /// The reader answered more bytes than the line buffer holds. Not a long
        /// line - a reader that is not answering about this buffer. The shell
        /// stops rather than parsing whatever is past the end of it.
        case overrun(Int)

        /// Nothing was typed, or nothing but spaces. Passed over in silence.
        case blank

        /// The line is not a command, and this says where it stopped being one.
        case refused(ParseFailure)

        /// Carried out, and the shell goes on reading.
        case carriedOut

        /// Carried out, and it asked the shell to stop. The last thing this
        /// engine does.
        case finished
    }

    public enum TypedStep: Equatable {
        case closed
        case readerGone
        case overrun(Int)
        case blank
        case refused(TypedShellFailure)
        case carriedOut
        case finished
    }


    /// Whether this shell reads another line. The loop's condition.
    public private(set) var reading = true

    /// How many bytes the line buffer holds. It is a real buffer's size, which is
    /// what bounds both the count a reader may answer and the caret's column.
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }


    /// Takes one line, hands it to `carryOut`, or says why it did not.
    ///
    /// `reading` is asked first, and that guard is the whole of the closing rule:
    /// a shell that has been told to stop reads nothing, parses nothing and runs
    /// nothing. It is asked here and not only in the loop's condition so that the
    /// rule holds for a caller who writes the loop differently, which is the
    /// mistake the rule exists to survive.
    ///
    /// Two counts are refused before the line is looked at, and both stop the
    /// shell rather than skipping a turn. A count below zero is the reader saying
    /// it is gone; a count above `capacity` is a reader answering about some
    /// other buffer, and parsing it walks off the end of this one. In neither
    /// case is asking the same reader again anything but a shell talking to
    /// something that is not there.
    ///
    /// A module does not stop the shell itself: it says it was asked to, and the
    /// stopping is one line below. `reading` is never set back to true, because
    /// `reading = !outcome.stopsTheShell` is the obvious way to write it and
    /// would let the next command undo an `exit`.
    public mutating func step(
        _ line  : UnsafePointer<UInt8>,
          count   : Int,
          carryOut: (Command) -> ShellOutcome
    ) -> Step {

        guard reading else { return .closed }

        guard count >= 0 else {
            reading = false
            return .readerGone
        }

        guard count <= capacity else {
            reading = false
            return .overrun(count)
        }

        guard count > 0 else { return .blank }

        switch CommandParser.parse(line, count: count) {
            case .failure(let failure):
                // A line of nothing but spaces is not a mistake to report.
                guard case .empty = failure.reason else { return .refused(failure) }

                return .blank

            case .success(let command):
                guard carryOut(command).stopsTheShell else { return .carriedOut }

                reading = false
                return .finished
        }
    }

    /// The production path: bounded parse to typed AST, then the caller-owned
    /// resolver/evaluator/service adapter. The compatibility `step` above stays
    /// available to old host clients, but `_start` uses this path exclusively.
    public mutating func stepTyped(
        _ line  : UnsafePointer<UInt8>,
          count   : Int,
          carryOut: (TypedShellProgram) -> Result<ShellOutcome, TypedShellFailure>
    ) -> TypedStep {
        guard reading else { return .closed }
        guard count >= 0 else { reading = false; return .readerGone }
        guard count <= capacity else { reading = false; return .overrun(count) }
        guard count > 0 else { return .blank }
        var visible = false
        for index in 0..<count
            where line[index] != 0x20 && line[index] != 0x0A && line[index] != 0x0D {
            visible = true
        }
        guard visible else { return .blank }
        switch TypedShellParser.parse(line, count: count) {
            case .failure(let failure): return .refused(failure)
            case .success(let program):
                switch carryOut(program) {
                    case .failure(let failure): return .refused(failure)
                    case .success(let outcome):
                        guard outcome.stopsTheShell else { return .carriedOut }
                        reading = false
                        return .finished
                }
        }
    }
}
