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

#if REIX_TERMINAL_PROFILE
    guard let profileMarker = environment.profileMarker else {
        exit(code: 1)
    }
    guard let profileStats = environment.profiler else {
        exit(code: 1)
    }
#endif

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
#if REIX_TERMINAL_PROFILE
        var submittedCorrelation: UInt32 = 0
#endif
        input: while true {
            guard let event = terminal.readInput() else { break input }
#if REIX_TERMINAL_PROFILE
            interactionMark(
                point      : .shellConsumed,
                correlation: event.sequence,
                value      : UInt32(event.count),
                authority  : profileMarker
            )
#endif
            let update = editor.apply(event)
#if REIX_TERMINAL_PROFILE
            interactionMark(
                point      : .editorCompleted,
                correlation: event.sequence,
                value      : min(UInt32(update.patch?.count ?? 0), InteractionTraceMark.maxValue),
                authority  : profileMarker
            )
#endif
            if let patch = update.patch, !terminal.present(patch) { break input }
            switch update.action {
                case .editing, .resized, .refused:
                    continue
                case .submitted(let length):
#if REIX_TERMINAL_PROFILE
                    submittedCorrelation = event.sequence
#endif
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

#if REIX_TERMINAL_PROFILE
        var parserMarked = false
#endif
        let step = line.span.withUnsafeBufferPointer { buffer in
            engine.stepTyped(buffer.baseAddress!, count: count) { program in
#if REIX_TERMINAL_PROFILE
                interactionMark(
                    point      : .parserCompleted,
                    correlation: submittedCorrelation,
                    value      : min(UInt32(clamping: count), InteractionTraceMark.maxValue),
                    authority  : profileMarker
                )
                parserMarked = true
#endif
                switch pipeline.execute(program, source: buffer.baseAddress!, count: count) {
                    case .failure(let failure): return .failure(failure)
                    case .success(let value):
                        guard pipeline.present(value) else { return .failure(.service(UInt32.max)) }
                        return .success(pipeline.outcome)
                }
            }
        }
#if REIX_TERMINAL_PROFILE
        if submittedCorrelation != 0 && !parserMarked {
            interactionMark(
                point      : .parserCompleted,
                correlation: submittedCorrelation,
                value      : min(UInt32(clamping: count), InteractionTraceMark.maxValue),
                authority  : profileMarker
            )
        }
#endif

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

#if REIX_TERMINAL_PROFILE
    guard writeTerminalBaselineSystem(authority: profileStats, to: &terminal) else {
        exit(code: 1)
    }
    guard writeTerminalBaselineProcesses(authority: profileStats, to: &terminal) else {
        exit(code: 1)
    }

    // Only the profiling image grants this capability `.profileConsole`; this
    // dump therefore describes the interaction run that just ended.
    profileDump(authority: profileMarker)
#endif

    // Said, because the terminal is shared: a prompt that simply stopped
    // appearing would read as a shell that had died. Init does not wait for this
    // process, so the machine carries on without a shell on it.
    print("[ SHELL ] this shell is done")
    guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }
    exit(code: 0)
}

#if REIX_TERMINAL_PROFILE
@inline(__always)
fileprivate func writeTerminalBaselineSystem(
    authority: UInt32,
    to terminal: inout Terminal
) -> Bool {
    var stats = SystemStats()
    ShellOutput.begin()
    if systemStats(into: &stats, authority: authority) {
        print("[ TERMINAL BASELINE ] system status=measured total_pages=", terminator: "")
        printDec(stats.totalPages, terminator: "")
        print(" free_pages=", terminator: "")
        printDec(stats.freePages, terminator: "")
        print(" counter_freq=", terminator: "")
        printDec(stats.counterFreq, terminator: "")
        print(" trace_lost=", terminator: "")
        printDec(stats.traceLost, terminator: "")
        print(" kernel_stack_peak_bytes=", terminator: "")
        printDec(UInt64(stats.kernelStackPeak), terminator: "")
        print(" exception_stack_peak_bytes=", terminator: "")
        printDec(UInt64(stats.exceptionStackPeak))
    } else {
        print("[ TERMINAL BASELINE ] system status=unavailable reason=stats-refused")
    }
    return ShellOutput.flush(to: &terminal)
}

@inline(__always)
fileprivate func writeTerminalBaselineProcesses(
    authority: UInt32,
    to terminal: inout Terminal
) -> Bool {
    ShellOutput.begin()
    var after   : UInt64 = 0
    var records = 0

    while records < 64 {
        var stats = ProcessStats()
        let pid   = nextProcessStats(after: after, into: &stats, authority: authority)
        guard pid != UInt64.max else { break }

        print("[ TERMINAL BASELINE ] process status=measured pid=", terminator: "")
        printDec(stats.pid, terminator: "")
        print(" name=", terminator: "")
        let length = min(Int(stats.nameLength), 16)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { name in
            for index in 0..<length { name[index] = stats.name[index] }
            printPadded(name.baseAddress!, count: length, width: 0)
        }
        print(" resident_pages=", terminator: "")
        printDec(UInt64(stats.residentPages), terminator: "")
        print(" stack_pages=", terminator: "")
        printDec(UInt64(stats.stackPages))

        after = pid
        records += 1
    }

    if records == 0 {
        print("[ TERMINAL BASELINE ] process status=unavailable reason=no-processes")
    } else if records == 64 {
        print("[ TERMINAL BASELINE ] process status=unavailable reason=scan-limit")
    }
    return ShellOutput.flush(to: &terminal)
}

@inline(__always)
fileprivate func interactionMark(
    point      : InteractionTracePoint,
    correlation: UInt32,
    value      : UInt32,
    authority  : UInt32
) {
    guard let mark = InteractionTraceMark(
        point      : point,
        correlation: correlation,
        value      : value
    ) else {
        return
    }
    profileInteractionMark(mark, authority: authority)
}
#endif

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
