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
    // Availability is queried before any optional system-register access. The
    // actual system snapshot is taken after the editor workload so heap and
    // stack high-water marks describe the same completed workload.
    var availabilityMetrics = SystemStats()
    let hasAvailabilityMetrics = systemStats(
        into: &availabilityMetrics,
        authority: profileStats
    )
    let pmuCycleAvailable = hasAvailabilityMetrics
        && (availabilityMetrics.availability & SystemMetricAvailability.pmuCycleCounter) != 0
    let instructionEventAvailable = pmuCycleAvailable
        && (availabilityMetrics.pmuEventAvailability
            & PMUEventAvailability.instructionsRetired) != 0
    guard writeTerminalEditorBaseline(
        pmuCycleAvailable: pmuCycleAvailable,
        instructionEventAvailable: instructionEventAvailable,
        to: &terminal
    ) else {
        exit(code: 1)
    }

    var systemMetrics = SystemStats()
    let hasSystemMetrics = systemStats(
        into: &systemMetrics,
        authority: profileStats
    )
    guard writeTerminalBaselineSystem(
        hasMetrics: hasSystemMetrics,
        metrics   : systemMetrics,
        to        : &terminal
    ) else { exit(code: 1) }

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
    pmuCycleAvailable: Bool,
    instructionEventAvailable: Bool,
    to terminal: inout InteractionSession
) -> Bool {
    var editor            = ShellLineEditor()
    var sequence          : UInt32 = 1
    var pasteDelta        : PMUDelta? = nil
    var pasteTimerTicks   : UInt64 = 0
    var pasteMeasured     = false

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: ReixInputProtocol.maximumPayload) { bytes in
        for index in 0..<bytes.count { bytes[index] = UInt8(ascii: "a") }

        let timerStart = readVirtualCounter()
        let section = OptionalPMUSection.begin(
            cyclesAvailable: pmuCycleAvailable,
            instructionsAvailable: instructionEventAvailable
        )
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
        let timerTicks = readVirtualCounter() &- timerStart

        guard update.action != .refused,
              update.requiresPresentation,
              editor.count == ShellLineEditor.capacity
        else { return }

        pasteDelta = delta
        pasteTimerTicks = timerTicks
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

    let layoutTimerStart = readVirtualCounter()
    let layoutSection = OptionalPMUSection.begin(
        cyclesAvailable: pmuCycleAvailable,
        instructionsAvailable: instructionEventAvailable
    )
    let layoutUpdate  = editor.apply(resize)
    let layoutDelta   = layoutSection.end()
    let layoutTimerTicks = readVirtualCounter() &- layoutTimerStart
    guard layoutUpdate.requiresPresentation,
          layoutUpdate.action != .refused,
          editor.count == ShellLineEditor.capacity
    else { return false }

    ShellOutput.begin()
    writeEditorMetric(workload: "paste-8192", timerTicks: pasteTimerTicks, delta: pasteDelta)
    writeEditorMetric(workload: "layout-8192", timerTicks: layoutTimerTicks, delta: layoutDelta)
    return ShellOutput.flush(to: &terminal)
}

@inline(__always)
fileprivate func writeEditorMetric(
    workload: StaticString,
    timerTicks: UInt64,
    delta: PMUDelta?
) {
    print("[ TERMINAL BASELINE ] editor status=measured workload=\(workload) bytes=8192 timer_unit=ticks timer_ticks=", terminator: "")
    printDec(timerTicks, terminator: "")
    if let delta {
        print(" pmu_status=available counter_unit=raw cycles=", terminator: "")
        printDec(delta.cycles, terminator: "")
        if let instructions = delta.instructions {
            print(" instruction_event_status=available instructions=", terminator: "")
            printDec(instructions)
        } else {
            print(" instruction_event_status=unavailable instruction_reason=inst-retired-not-advertised")
        }
    } else {
        print(" pmu_status=unavailable reason=pmu-counters-unavailable")
    }
}

@inline(__always)
fileprivate func writeTerminalBaselineSystem(
    hasMetrics: Bool,
    metrics   : SystemStats,
    to terminal: inout InteractionSession
) -> Bool {
    ShellOutput.begin()

    let requiredAvailability = SystemMetricAvailability.physicalMemory
        | SystemMetricAvailability.kernelHeap
        | SystemMetricAvailability.stacks
        | SystemMetricAvailability.timer
    if hasMetrics,
       (metrics.availability & requiredAvailability) == requiredAvailability {
        print("[ TERMINAL BASELINE ] system status=measured page_bytes=4096 physical_total_pages=", terminator: "")
        printDec(metrics.physicalTotalPages, terminator: "")

        print(" physical_allocated_pages=", terminator: "")
        printDec(metrics.physicalAllocatedPages, terminator: "")

        print(" physical_free_pages=", terminator: "")
        printDec(metrics.physicalFreePages, terminator: "")

        print(" kernel_heap_live_capacity_bytes=", terminator: "")
        printDec(metrics.kernelHeapLiveBytes, terminator: "")

        print(" kernel_heap_live_high_water_bytes=", terminator: "")
        printDec(metrics.kernelHeapLiveHighWaterBytes, terminator: "")

        print(" kernel_heap_reserved_bytes=", terminator: "")
        printDec(metrics.kernelHeapReservedBytes, terminator: "")

        print(" kernel_heap_reserved_high_water_bytes=", terminator: "")
        printDec(metrics.kernelHeapReservedHighWaterBytes, terminator: "")

        print(" timer_frequency_hz=", terminator: "")
        printDec(metrics.timerFrequency, terminator: "")

        print(" trace_lost=", terminator: "")
        printDec(metrics.traceLost, terminator: "")

        print(" kernel_stack_used_high_water_bytes=", terminator: "")
        printDec(UInt64(metrics.kernelStackUsedBytes), terminator: "")

        print(" kernel_stack_capacity_bytes=", terminator: "")
        printDec(UInt64(metrics.kernelStackCapacity), terminator: "")

        print(" exception_stack_used_high_water_bytes=", terminator: "")
        printDec(UInt64(metrics.exceptionStackUsedBytes), terminator: "")

        print(" exception_stack_capacity_bytes=", terminator: "")
        printDec(UInt64(metrics.exceptionStackCapacity), terminator: "")

        let pmuAvailable = (metrics.availability & SystemMetricAvailability.pmuCycleCounter) != 0
        print(" pmu_status=", terminator: "")
        print(pmuAvailable ? "available" : "unavailable", terminator: "")
        if pmuAvailable {
            print(" pmu_event_counters=", terminator: "")
            printDec(UInt64(metrics.pmuEventCounters), terminator: "")
            let instructionsAvailable = (metrics.pmuEventAvailability
                & PMUEventAvailability.instructionsRetired) != 0
            print(" instruction_event_status=", terminator: "")
            if instructionsAvailable {
                print("available")
            } else {
                print("unavailable instruction_reason=inst-retired-not-advertised")
            }
        } else {
            print(" pmu_reason=pmu-cycle-counter-unavailable")
        }

    } else {
        print("[ TERMINAL BASELINE ] system status=unavailable reason=stats-refused-or-unmeasured")
    }

    print("[ TERMINAL BASELINE ] user_heap status=measured process=Shell.elf domain=virtual-reservation unit=bytes reserved_bytes=", terminator: "")
    printDec(UInt64(userHeapReservedBytes()), terminator: "")
    print(" high_water_bytes=", terminator: "")
    printDec(UInt64(userHeapHighWaterBytes()))

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
        let pid = nextProcessStats(after: after, into: &stats, authority: authority)

        guard pid != UInt64.max else { break }

        let requiredAvailability = ProcessMetricAvailability.virtualExtent
            | ProcessMetricAvailability.mappedPages
            | ProcessMetricAvailability.stack
        let valid = (stats.availability & requiredAvailability) == requiredAvailability

        print("[ TERMINAL BASELINE ] process status=", terminator: "")
        print(valid ? "measured" : "unavailable", terminator: "")
        print(" mapped_semantics=address-space-nonunique pid=", terminator: "")
        printDec(stats.pid, terminator: "")

        print(" name=", terminator: "")

        let length = min(Int(stats.nameLength), 16)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { name in
            for index in 0..<length { name[index] = stats.name[index] }
            printPadded(name.baseAddress!, count: length, width: 0)
        }

        if valid {
            print(" mapped_pages=", terminator: "")
            printDec(UInt64(stats.mappedPages), terminator: "")

            print(" virtual_extent_pages=", terminator: "")
            printDec(stats.virtualExtentPages, terminator: "")

            print(" stack_extent_pages=", terminator: "")
            printDec(UInt64(stats.stackExtentPages), terminator: "")

            print(" stack_capacity_pages=", terminator: "")
            printDec(UInt64(stats.stackCapacityPages))
        } else {
            print(" reason=address-space-metrics-unavailable")
        }

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
