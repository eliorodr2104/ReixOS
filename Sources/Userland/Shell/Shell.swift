//
//  Shell.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI
import ShellLanguage


/// The shell owns semantic input and TextSurface presentation.
/// Every other authority arrives through an explicit capability.
@_cdecl("_start")
public func main() {

    var environment = Runtime.bootstrap()

#if REIX_TERMINAL_PROFILE
    guard let profileMarker = environment.profileMarker else {
        exit(code: 1)
    }
    guard let profileStats = environment.profiler else {
        exit(code: 1)
    }
#endif

    guard let input = environment.inputConsumer,
          let textSurface = environment.terminal
    else { exit(code: 1) }

    guard var terminal = InteractionSession(input: input, textSurface: textSurface) else {
        exit(code: 1)
    }

    ShellOutput.begin()
    print("")
    print("ReixOS shell. Type Shell.help() to see what this understands.")
    print("")
    guard ShellOutput.flush(to: &terminal) else {
        exit(code: 1)
    }
    guard environment.signalReady() else { exit(code: 1) }

    // One catalog, read by all three: the editor colours with it, the parser
    // resolves receivers against it, and the pipeline dispatches through it.
    let modules  = ShellModuleRegistry.builtIn()
    let catalog  = modules.catalog
    var editor   = ShellLineEditor(catalog: catalog)
    var pipeline = ShellPipeline(environment: environment, modules: modules)
    var engine   = ShellEngine(
        capacity  : ShellLineEditor.capacity,
        namespaces: catalog.namespaceSet()
    )

    while engine.reading {
        // A refused frame is the adapter asking for a resend.
        if !editor.withFrame(completingWith: { snapshot, source, count, offered in
            pipeline.complete(for: snapshot, source: source, count: count, into: &offered)
        }, { terminal.present($0) }) {
            if terminal.needsEditorSnapshot { editor.requireSnapshot() }
            if !editor.withFrame(completingWith: { snapshot, source, count, offered in
                pipeline.complete(for: snapshot, source: source, count: count, into: &offered)
            }, { terminal.present($0) }), !terminal.isUsable {
                exit(code: 1)
            }
        }

        var count = -1
#if REIX_TERMINAL_PROFILE
        var submittedCorrelation: UInt32 = 0
#endif
        input: while true {
            guard let event = terminal.nextInput() else { break input }

#if REIX_TERMINAL_PROFILE
            interactionMark(
                point      : .shellConsumed,
                correlation: event.sequence,
                value      : UInt32(event.count),
                authority  : profileMarker
            )
#endif

            let update = editor.apply(event, completingWith: { snapshot, source, count, offered in
                pipeline.complete(for: snapshot, source: source, count: count, into: &offered)
            })

#if REIX_TERMINAL_PROFILE
            interactionMark(
                point      : .editorCompleted,
                correlation: event.sequence,
                value      : update.requiresPresentation ? UInt32(editor.count) : 0,
                authority  : profileMarker
            )
#endif
            if update.requiresPresentation, !editor.withFrame(completingWith: { snapshot, source, count, offered in
                pipeline.complete(for: snapshot, source: source, count: count, into: &offered)
            }, { terminal.present($0) }) {
                if terminal.needsEditorSnapshot { editor.requireSnapshot() }
                if !editor.withFrame(completingWith: { snapshot, source, count, offered in
                    pipeline.complete(for: snapshot, source: source, count: count, into: &offered)
                }, { terminal.present($0) }), !terminal.isUsable {
                    break input
                }
            }

            switch update.action {
                case .editing, .refused:
                    continue

                case .resized(let width, let height):
                    _ = terminal.resize(
                        width      : width,
                        height     : height,
                        correlation: event.sequence
                    )
                    continue

                case .submitted(let length):

#if REIX_TERMINAL_PROFILE
                    submittedCorrelation = event.sequence
#endif

                    guard length <= ShellLineEditor.capacity else { count = -1; break input }
                    count = length
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

        let submittedAsCode = editor.isCodeEditing
        terminal.finishEditor(sequence: ShellOutput.nextSequence())
        ShellOutput.begin()
        if count >= 0, !submittedAsCode { print("") }

#if REIX_TERMINAL_PROFILE
        var parserMarked = false
#endif

        let step = editor.withBytes { source, actualCount in
            guard count <= actualCount else { return ShellEngine.TypedStep.overrun(count) }
            return engine.stepTyped(source, count: count) { program in

#if REIX_TERMINAL_PROFILE
                interactionMark(
                    point      : .parserCompleted,
                    correlation: submittedCorrelation,
                    value      : min(UInt32(clamping: count), InteractionTraceMark.maxValue),
                    authority  : profileMarker
                )
                parserMarked = true
#endif

                switch pipeline.execute(
                    program,
                    source: source,
                    count : count,
                    flush : {
                        guard ShellOutput.flush(to: &terminal) else { return false }
                        ShellOutput.begin()
                        return true
                    }
                ) {
                    case .failure(let failure):
                        return .failure(failure)

                    case .success(let value):
                        guard pipeline.present(value) else {
                            return .failure(.service(UInt32.max))
                        }

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
                var presentedCodeDiagnostic = false
                if submittedAsCode {
                    editor.withBytes { source, actualCount in
                        let submittedCount = min(max(0, count), actualCount)
                        presentedCodeDiagnostic = reportCodeFailure(
                            failure,
                            source: source,
                            count: submittedCount
                        )
                        if !presentedCodeDiagnostic {
                            report(failure, engine: engine)
                        }
                    }
                } else {
                    report(failure, engine: engine)
                }
                if presentedCodeDiagnostic {
                    guard ShellOutput.flushDiagnostic(to: &terminal) else { exit(code: 1) }
                    ShellOutput.begin()
                }

            case .blank, .carriedOut, .finished, .closed:
                break
        }

        // A module cannot clear a terminal; it can say that it asked. This is
        // the one place that holds one.
        if pipeline.outcome == .clearRequested {
            _ = terminal.clear(sequence: ShellOutput.nextSequence())
            editor.requireSnapshot()
        }

        if count >= 0 { editor.reset() }

        guard ShellOutput.flush(to: &terminal) else { exit(code: 1) }

    }

#if REIX_TERMINAL_PROFILE
    guard writeTerminalEditorBaseline(to: &terminal) else {
        exit(code: 1)
    }

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
fileprivate func writeTerminalEditorBaseline(
    to terminal: inout InteractionSession
) -> Bool {
    var editor            = ShellLineEditor()
    var sequence          : UInt32 = 1
    var pasteCycles       : UInt64 = 0
    var pasteInstructions : UInt64 = 0
    var pasteMeasured     = false

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: ReixInputProtocol.maximumPayload) { bytes in
        for index in 0..<bytes.count { bytes[index] = UInt8(ascii: "a") }

        let section = PMUSection.begin()
        guard let begin = ReixInputRecord(kind: .pasteBegin, sequence: sequence) else { return }
        sequence += 1
        _ = editor.apply(begin)

        for _ in 0..<(ShellLineEditor.capacity / ReixInputProtocol.maximumPayload) {
            guard let chunk = ReixInputRecord(
                kind: .pasteChunk,
                sequence: sequence,
                bytes: bytes.baseAddress!,
                count: bytes.count
            ) else { return }
            sequence += 1
            let update = editor.apply(chunk)
            guard update.action != .refused else { return }
        }

        guard let end = ReixInputRecord(kind: .pasteEnd, sequence: sequence) else { return }
        sequence += 1
        let update = editor.apply(end)
        let delta  = section.end()

        guard update.action != .refused,
              update.requiresPresentation,
              editor.count == ShellLineEditor.capacity
        else { return }

        pasteCycles = delta.cycles
        pasteInstructions = delta.instructions
        pasteMeasured = true
    }

    guard pasteMeasured,
          let resize = ReixInputRecord(
              kind: .resize,
              sequence: sequence,
              width: 120,
              height: 40
          )
    else { return false }

    let layoutSection = PMUSection.begin()
    let layoutUpdate  = editor.apply(resize)
    let layoutDelta   = layoutSection.end()
    guard layoutUpdate.requiresPresentation,
          layoutUpdate.action != .refused,
          editor.count == ShellLineEditor.capacity
    else { return false }

    ShellOutput.begin()
    print("[ TERMINAL BASELINE ] editor status=measured workload=paste-8192 bytes=8192 cycles=", terminator: "")
    printDec(pasteCycles, terminator: "")
    print(" instructions=", terminator: "")
    printDec(pasteInstructions)
    print("[ TERMINAL BASELINE ] editor status=measured workload=layout-8192 bytes=8192 cycles=", terminator: "")
    printDec(layoutDelta.cycles, terminator: "")
    print(" instructions=", terminator: "")
    printDec(layoutDelta.instructions)
    return ShellOutput.flush(to: &terminal)
}

@inline(__always)
fileprivate func writeTerminalBaselineSystem(
       authority: UInt32,
    to terminal : inout InteractionSession
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

        print(" heap_high_water_bytes=", terminator: "")
        printDec(UInt64(userHeapHighWaterBytes()), terminator: "")

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
    to terminal : inout InteractionSession
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
    ) else { return }

    profileInteractionMark(mark, authority: authority)
}
#endif

private func reportCodeFailure(
    _ failure: TypedShellFailure,
    source   : UnsafePointer<UInt8>,
    count    : Int
) -> Bool {
    let offset : Int
    let message: StaticString
    switch failure {
        case .syntax(let column):
            offset = column
            message = "syntax error"
        case .incomplete:
            offset = count
            message = "the expression is incomplete"
        default:
            return false
    }

    let location = codeLocation(source: source, count: count, offset: offset)
    var spaces   = ReixCodeEditorLayout.standardGutterColumns + UInt16(location.column)
    while spaces > 0 {
        putchar(ch: 0x20)
        spaces -= 1
    }
    print("^  ", terminator: "")
    print(message, terminator: "")
    print(" at line ", terminator: "")
    printDec(UInt64(location.line), terminator: "")
    print(", column ", terminator: "")
    printDec(UInt64(location.column + 1))
    return true
}

private func codeLocation(
    source: UnsafePointer<UInt8>,
    count : Int,
    offset: Int
) -> (line: Int, column: Int, lineStart: Int, lineEnd: Int) {
    let target    = min(max(0, offset), count)
    var line      = 1
    var lineStart = 0
    var index     = 0
    while index < target {
        if source[index] == 0x0A {
            line += 1
            lineStart = index + 1
        } else if source[index] == 0x0D {
            if index + 1 < target, source[index + 1] == 0x0A { index += 1 }
            line += 1
            lineStart = index + 1
        }
        index += 1
    }

    var lineEnd = lineStart
    while lineEnd < count, source[lineEnd] != 0x0A, source[lineEnd] != 0x0D {
        lineEnd += 1
    }
    let columnEnd = min(target, lineEnd)
    var column    = 0
    var cursor    = lineStart
    while cursor < columnEnd {
        guard let next = ReixTextLayout.nextGraphemeBoundary(
            after: cursor,
            count: lineEnd,
            byte: { source[$0] }
        ),
              next <= columnEnd,
              let width = ReixTextLayout.cellWidth(
                  from: cursor,
                  to: next,
                  count: lineEnd,
                  byte: { source[$0] }
              )
        else {
            column += columnEnd - cursor
            break
        }
        column += Int(width)
        cursor = next
    }
    return (line, column, lineStart, lineEnd)
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
        case .syntax:
            print("       syntax error")

        case .incomplete:
            print("       the expression is incomplete")

        case .programLimit:
            print("       this turn exceeds the shell budget")

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

        case .wrongArguments:
            print("       arguments do not match the signature")

        case .type:
            print("       expression has the wrong type")

        case .unsupportedMember:
            print("       this value has no such member")

        case .service(let status):
            print("       service refused with status ", terminator: "")
            printDec(UInt64(status))

        case .materializationLimit(let limit):
            print("       materialization budget exceeded: ", terminator: "")
            printDec(UInt64(limit))

        case .cancelled:
            print("       cancelled")
    }
}
