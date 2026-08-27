//
//  Shell.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI
import ShellLanguage


/// The terminal, written against `Terminal` and the capabilities this process
/// was handed, and against nothing else.
///
/// Commands are spelled `receiver.verb(arguments)` from the first version on,
/// because that shape is not a style: the receiver names the authority the
/// command is exercised through. `process.spawn("Top.elf")` is a use of a
/// capability this shell holds, and a shell that did not hold it would have no
/// `process` to type. The structured terminal this system is aiming at grows
/// out of that sentence, not out of a list of bare words.
///
/// What ends the loop is `ShellEngine`, and it is the engine rather than a flag
/// read here because the rule that has to hold is stronger than a loop
/// condition: once the engine has been asked to stop it refuses a line even if
/// somebody writes the loop wrong. What is left in this function is the two
/// things only it can do, calling a reader and printing.
@_cdecl("_start")
public func main() {

    let environment = Runtime.bootstrap()

    guard let service = environment.terminal else {
        exit(code: 1)
    }

    guard var terminal = Terminal(endpoint: service) else {
        exit(code: 1)
    }

    ShellOutput.begin()
    print("")
    print("ReixOS shell. Type shell.help() to see what this understands.")
    print("")
    guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }

    var line     = InlineArray<256, UInt8>(repeating: 0)
    var editor   = ShellLineEditor()
    var engine   = ShellEngine(capacity: line.count)
    var pipeline = ShellPipeline(environment: environment)

    while engine.reading {
        ShellOutput.begin()
        print("reix> ", terminator: "")
        guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }

        var count = -1
        input: while true {
            guard let event = terminal.readInput() else { break input }
            let update = editor.apply(event)
            if let patch = update.patch, !terminal.present(patch) { break input }
            switch update.action {
                case .editing, .resized, .refused:
                    continue
                case .submitted(let length):
                    count = editor.copyLine(into: &line)
                    guard count == length else { count = -1; break input }
                    editor.reset()
                    break input
                case .cancelled:
                    editor.reset()
                    count = 0
                    break input
                case .eof:
                    count = -1
                    break input
            }
        }
        ShellOutput.begin()

        let step = line.span.withUnsafeBufferPointer { buffer in
            engine.stepTyped(buffer.baseAddress!, count: count) { program in
                switch pipeline.execute(program, source: buffer.baseAddress!, count: count) {
                    case .failure(let failure): return .failure(failure)
                    case .success(let value):
                        guard pipeline.present(value) else { return .failure(.service(UInt32.max)) }
                        return .success(pipeline.outcome)
                }
            }
        }

        switch step {
            // Nothing this process printed afterwards would be read by anybody,
            // so it stops rather than spinning on a dead handle.
            case .readerGone:
                print("[ SHELL ] the terminal went away")
                guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }
                exit(code: 1)

            case .overrun(let count):
                print("[ SHELL ] the terminal answered ", terminator: "")
                printDec(UInt64(count), terminator: "")
                print(" bytes for a line this shell cannot hold")
                guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }
                exit(code: 1)

            case .refused(let failure):
                report(failure, engine: engine)

            case .blank, .carriedOut, .finished, .closed:
                break
        }
        guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }
    }

    // Said, because the terminal is shared: a prompt that simply stopped
    // appearing would read as a shell that had died. Init does not wait for this
    // process, so the machine carries on without a shell on it.
    print("[ SHELL ] this shell is done")
    guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }
    exit(code: 0)
}
private func report(
    _ failure: TypedShellFailure,
      engine : ShellEngine
) {
    let column: Int
    switch failure {
        case .syntax(let placed): column = placed
        default: column = 0
    }
    var spaces = engine.caret(under: column)
    while spaces > 0 { putchar(ch: 0x20); spaces -= 1 }
    print("^")
    switch failure {
        case .syntax: print("       syntax error")
        case .incomplete: print("       the expression is incomplete")
        case .programLimit: print("       this turn exceeds the shell budget")
        case .unknownSymbol(let name):
            print("       no such symbol: ", terminator: "")
            name.withBytes { printPadded($0, count: $1, width: 0) }
            print("")
        case .ambiguousCall(let name, let count):
            print("       ambiguous call: ", terminator: "")
            name.withBytes { printPadded($0, count: $1, width: 0) }
            print(" (", terminator: "")
            printDec(UInt64(count), terminator: "")
            print(" candidates); write the namespace")
        case .wrongArguments: print("       arguments do not match the signature")
        case .type: print("       expression has the wrong type")
        case .unsupportedMember: print("       this value has no such member")
        case .service(let status):
            print("       service refused with status ", terminator: "")
            printDec(UInt64(status))
        case .materializationLimit(let limit):
            print("       materialization budget exceeded: ", terminator: "")
            printDec(UInt64(limit))
        case .cancelled: print("       cancelled")
    }
}
