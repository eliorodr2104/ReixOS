import PackagePlugin
import Foundation

/// Host-side decoder for the kernel's trace ring dump.
///
/// On request the OS prints its trace ring to the serial console as a
/// series of `[TRACE] `-prefixed lines, which may appear anywhere in a
/// captured console log that also carries ordinary output:
///
///     [TRACE] begin v=2 freq=DEC lost=DEC stack=DEC exstack=DEC
///     [TRACE] t=DEC ev=NAME pid=DEC info=DEC a=VAL b=VAL
///     [TRACE] end count=DEC
///
/// The event line's six fields are always present, single-spaced, in that
/// fixed order (one line per event, oldest first). `freq` is CNTFRQ in Hz
/// (62500000 on QEMU virt). `t` is the raw 64-bit counter; `pid` is 32-bit;
/// `info` is 16-bit. `a`/`b` are 64-bit and may each be written as a plain
/// unsigned decimal or as `0x` + lowercase hex, the base picked per field
/// from the presence of the `0x` prefix rather than a table of which fields
/// are address-like. `ev` spells out the event class by name (mapping back
/// to the numeric code the views below key on); an as-yet-unnamed code
/// still round-trips as `ev=0x` followed by its four hex digits. A log may
/// carry more than one dump; the decoder always reports the last complete
/// one.
///
/// Event classes (`code >> 8`):
///   0x01 syscallExit  info=raw syscall number, a=duration, b=return x0
///   0x02 ctxSwitch (0x0200), idleEnter (0x0201), idleExit (0x0202);
///        ctxSwitch: a=prev pid, b=next pid
///   0x03 ipcBlock (0x0300, info: 0 sendQueue/1 recvWait/2 call, a=endpoint),
///        ipcWake (0x0301, a=woken pid), ipcTransfer (0x0302, a=sender, b=receiver)
///   0x04 preemptSpan (0x0400): info=region slot, a=longest stretch, b=checkpoints
///   0x05 sample (0x0500, info bit0=1 for an EL1 hit, a=ELR, b=x30),
///        sampleFrame (0x0501, info=depth 1-4, a=return address; frames
///        belong to the immediately preceding EL1 sample)
///   0x06 pmuSection (0x0600, info=section id, a=cycle delta, b=instruction
///        delta; TCG counters are approximate), pmuEvents (0x0601, a/b=extra
///        event-counter deltas)
///   0x07 bootPhase (0x0700): info=phase id
///   0x08 procSpawn (0x0800, a=new pid, b=parent pid), procName (0x0801,
///        pid=named process, info=name length, a/b=name bytes 0-15 little-endian),
///        procExit (0x0802, a=pid)
///   0x09 interactionMark (0x0900, info=InteractionTracePoint, a=correlation,
///        b=value)
enum TraceDecoder {

    // MARK: - Entry point

    /// `arguments[0]` is the subcommand name ("trace"); the rest is the
    /// logfile path plus an optional `--boot`/`--raw`/`--profile`/`--interaction` flag.
    /// `root` is the package directory, needed by `--profile` to find
    /// `.reix/kernel.elf` and the per-process `.reix/<Name>` ELFs.
    static func run(arguments: [String], root: URL) throws {
        let rest = Array(arguments.dropFirst())
        let mode: Mode = rest.contains("--export") ? .export
            : rest.contains("--interaction") ? .interaction
            : rest.contains("--boot") ? .boot
            : rest.contains("--raw") ? .raw
            : rest.contains("--profile") ? .profile
            : .summary

        // Not a plain "first token without --" scan: `--symbolizer` takes a
        // value that must not be mistaken for the logfile path.
        var logPath   : String?
        var exportPath: String?
        var index = 0
        while index < rest.count {
            let token = rest[index]

            // Both of these take a value, which must not be mistaken for the
            // logfile path.
            if token == "--symbolizer" { index += 2; continue }
            if token == "--export" {
                exportPath = index + 1 < rest.count ? rest[index + 1] : nil
                index += 2
                continue
            }

            if token.hasPrefix("--") { index += 1; continue }

            logPath = logPath ?? token
            index += 1
        }

        guard let logPath else {
            Diagnostics.error("""
            Usage: swift package reix trace <logfile> [--boot|--raw|--profile|--interaction]
                       [--export <out.json>]   writes a Chrome Trace Event file,
                                               which ui.perfetto.dev opens
                       [--symbolizer <path>]   (only consulted by --profile)
            """)
            return
        }

        let text: String
        do {
            text = try String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
        } catch {
            Diagnostics.error("Could not read \(logPath): \(error)")
            return
        }

        let lines = text.components(separatedBy: .newlines)

        let extraction: Extraction
        do {
            extraction = try extractLastBlock(from: lines)
        } catch let error as ExtractionError {
            Diagnostics.error(error.description)
            return
        }

        if let warning = extraction.danglingWarning {
            Diagnostics.warning(warning)
        }

        let block = extraction.block
        if extraction.malformedCount > 0 {
            Diagnostics.warning("\(extraction.malformedCount) malformed trace line(s) skipped.")
        }
        if block.declaredCount != UInt64(block.events.count) {
            Diagnostics.warning("""
            Block declared count=\(block.declaredCount) but \(block.events.count) event(s) \
            parsed; the difference is malformed or skipped lines within the block.
            """)
        }

        switch mode {
            case .summary: printSummary(block)
            case .boot   : printBoot(block)
            case .raw    : printRaw(block)
            case .profile: printProfile(block, root: root, arguments: arguments)
            case .interaction: printInteraction(block)

            case .export:
                guard let exportPath else {
                    Diagnostics.error("--export needs a path to write to.")
                    return
                }

                export(block, to: exportPath)
        }
    }

    private enum Mode { case summary, boot, raw, profile, interaction, export }

    private static func printInteraction(_ block: TraceBlock) {
        struct Group {
            let correlation: UInt32
            let firstTimestamp: UInt64
            var points: [UInt16: TraceEvent] = [:]
            var duplicates: Set<UInt16> = []
        }
        var groups: [Group] = []
        var invalid = 0
        for event in block.events where event.code == 0x0900 {
            guard (1...10).contains(event.info), event.a <= UInt64(UInt32.max), event.b <= 0x00FF_FFFF else {
                invalid += 1
                continue
            }
            let correlation = UInt32(event.a)
            let index       = groups.firstIndex { $0.correlation == correlation }
            if let index {
                if groups[index].points[event.info] != nil { groups[index].duplicates.insert(event.info) }
                else { groups[index].points[event.info] = event }
            } else { groups.append(Group(correlation: correlation, firstTimestamp: event.ts, points: [event.info: event])) }
        }
        print("interaction groups=\(groups.count) invalid=\(invalid)")
        func duration(
            _ group: Group,
            _ start: UInt16,
            _ end  : UInt16
        ) -> String {
            guard !group.duplicates.contains(start), !group.duplicates.contains(end), let a = group.points[start], let b = group.points[end], b.ts >= a.ts else { return "unavailable" }
            return "\(fmt(micros(b.ts - a.ts, freq: block.freq)))us"
        }
        for group in groups {
            let consoleAcknowledgement = !group.duplicates.contains(7) ? group.points[7] : nil
            let renderedBytes = consoleAcknowledgement.map { String($0.b) } ?? "unavailable"
            let wire: String
            if let consoleAcknowledgement {
                wire = "\(fmt(Double(consoleAcknowledgement.b) * 10_000_000.0 / 115_200.0))us"
            } else {
                wire = "unavailable"
            }
            let provenance = consoleAcknowledgement == nil
                ? "unavailable"
                : "estimated-115200-8n1"
            let fullBytes = group.points[8].map { String($0.b) } ?? "unavailable"
            let diffBytes = group.points[9].map { String($0.b) } ?? "unavailable"
            let plan = group.points[10].map { $0.b == 1 ? "diff" : "full" } ?? "unavailable"
            print(
                "interaction correlation=\(group.correlation) " +
                "serial_delivery_to_decoded=\(duration(group, 1, 2)) " +
                "decoded_to_shell=\(duration(group, 2, 3)) " +
                "shell_to_editor=\(duration(group, 3, 4)) " +
                "editor_to_parser=\(duration(group, 4, 5)) " +
                "editor_to_presentation=\(duration(group, 4, 6)) " +
                "presentation_to_console_ack=\(duration(group, 6, 7)) " +
                "total=\(duration(group, 1, 7)) " +
                "rendered_bytes=\(renderedBytes) " +
                "full_estimate_bytes=\(fullBytes) " +
                "diff_estimate_bytes=\(diffBytes) " +
                "render_plan=\(plan) " +
                "wire_time_estimate=\(wire) " +
                "wire_provenance=\(provenance) " +
                "duplicate=\(group.duplicates.count)"
            )
        }
    }
}


// MARK: - Parsing

extension TraceDecoder {

    struct TraceEvent {
        let ts   : UInt64
        let code : UInt16
        let info : UInt16
        let pid  : UInt32
        let a    : UInt64
        let b    : UInt64
    }

    struct TraceBlock {
        let startLine     : Int
        let freq          : UInt64
        let lost          : UInt64
        let stack         : UInt64
        let exceptionStack: UInt64
        let endLine       : Int
        let declaredCount : UInt64
        let events        : [TraceEvent]
    }

    struct Extraction {
        let block            : TraceBlock
        let malformedCount    : Int
        let danglingWarning   : String?
    }

    enum ExtractionError: Error, CustomStringConvertible {
        case noBlock
        case truncated(startLine: Int)

        var description: String {
            switch self {
                case .noBlock:
                    return "No trace block ([TRACE] begin ... / [TRACE] end ...) found in the log."
                case .truncated(let line):
                    return """
                    Truncated trace block: 'begin' at line \(line) has no matching 'end'. \
                    The capture likely cut off mid-dump.
                    """
            }
        }
    }

    /// The fixed prefix every trace line carries after optional local VT state.
    private static let tracePrefix = "[TRACE] "

    /// Scans every line once, tracking the currently open begin/end block. A
    /// fresh begin abandons whatever block was still open (an earlier dump
    /// that never got its end); only the last completed block is returned.
    private static func extractLastBlock(from lines: [String]) throws -> Extraction {
        struct OpenBlock {
            var startLine: Int
            var freq: UInt64
            var lost: UInt64
            var stack: UInt64
            var exceptionStack: UInt64
            var events: [TraceEvent]
        }

        var open: OpenBlock?
        var completed: [TraceBlock] = []
        var malformed = 0

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            guard let payload = tracePayload(line) else { continue }

            // Splitting without collapsing empty runs makes a double space
            // (or a missing field) misalign the tokens, so it fails the
            // per-line grammar below exactly like the "single spaces" rule asks.
            let tokens = payload.split(separator: " ", omittingEmptySubsequences: false)
            guard let first = tokens.first else { malformed += 1; continue }

            if first == "begin" {
                guard let header = parseBeginLine(tokens) else { malformed += 1; continue }
                open = OpenBlock(
                    startLine: lineNumber, freq: header.freq, lost: header.lost,
                    stack: header.stack, exceptionStack: header.exceptionStack, events: []
                )
                continue
            }

            if first == "end" {
                guard let count = parseEndLine(tokens) else { malformed += 1; continue }
                guard let current = open else { malformed += 1; continue } // end without begin
                completed.append(TraceBlock(
                    startLine: current.startLine, freq: current.freq, lost: current.lost,
                    stack: current.stack, exceptionStack: current.exceptionStack,
                    endLine: lineNumber, declaredCount: count, events: current.events
                ))
                open = nil
                continue
            }

            // Only remaining valid shape is an event line; anything else
            // carrying the trace prefix fails the grammar outright.
            guard first.hasPrefix("t=") else { malformed += 1; continue }
            guard let event = parseEventLine(tokens) else { malformed += 1; continue }
            open?.events.append(event) // outside any block: silently dropped, not malformed
        }

        guard let last = completed.last else {
            if let open { throw ExtractionError.truncated(startLine: open.startLine) }
            throw ExtractionError.noBlock
        }

        let warning = open.map {
            "A later trace dump starting at line \($0.startLine) has no matching end; ignoring it " +
            "and showing the last complete dump (lines \(last.startLine)-\(last.endLine))."
        }

        return Extraction(block: last, malformedCount: malformed, danglingWarning: warning)
    }

    /// A screen redraw may leave local CSI state before an otherwise exact trace record.
    private static func tracePayload(_ line: String) -> Substring? {
        var remaining = line[...]
        while remaining.hasPrefix("\u{001B}[") {
            var index = remaining.index(remaining.startIndex, offsetBy: 2)
            var foundFinal = false
            while index < remaining.endIndex {
                let character = remaining[index]
                guard character.unicodeScalars.count == 1,
                      let scalar = character.unicodeScalars.first
                else { return nil }
                let value = scalar.value
                index = remaining.index(after: index)
                if value >= 0x40 && value <= 0x7E {
                    remaining = remaining[index...]
                    foundFinal = true
                    break
                }
                guard value >= 0x20 && value <= 0x3F else { return nil }
            }
            guard foundFinal else { return nil }
        }
        guard remaining.hasPrefix(tracePrefix) else { return nil }
        return remaining.dropFirst(tracePrefix.count)
    }

    /// `begin v=2 freq=DEC lost=DEC stack=DEC exstack=DEC`: exactly six
    /// tokens, `v=2` literal (the only wire version this decoder speaks; a
    /// `v=1` log, which carried no stack figures, is refused rather than
    /// half-read, which is the whole reason the field is on the line).
    private static func parseBeginLine(
        _ tokens: [Substring]
    ) -> (freq: UInt64, lost: UInt64, stack: UInt64, exceptionStack: UInt64)? {
        guard tokens.count == 6, tokens[1] == "v=2" else { return nil }
        guard let freq     = decimalField(tokens[2], key: "freq")    else { return nil }
        guard let lost     = decimalField(tokens[3], key: "lost")    else { return nil }
        guard let stack    = decimalField(tokens[4], key: "stack")   else { return nil }
        guard let exstack  = decimalField(tokens[5], key: "exstack") else { return nil }
        return (freq, lost, stack, exstack)
    }

    /// `end count=DEC`: exactly two tokens.
    private static func parseEndLine(_ tokens: [Substring]) -> UInt64? {
        guard tokens.count == 2 else { return nil }
        return decimalField(tokens[1], key: "count")
    }

    /// `t=DEC ev=NAME pid=DEC info=DEC a=VAL b=VAL`: six tokens in that fixed
    /// order. A reordered or missing field, or an unrecognized `ev` name,
    /// fails the grammar and the whole line counts as malformed.
    private static func parseEventLine(_ tokens: [Substring]) -> TraceEvent? {
        guard tokens.count == 6 else { return nil }
        guard let ts     = decimalField(tokens[0], key: "t")  else { return nil }
        guard let evName = rawField(tokens[1], key: "ev")     else { return nil }
        guard let code   = eventCode(for: evName)             else { return nil }
        guard let pid64  = decimalField(tokens[2], key: "pid"), pid64  <= UInt64(UInt32.max)
        else { return nil }
        guard let info64 = decimalField(tokens[3], key: "info"), info64 <= UInt64(UInt16.max)
        else { return nil }
        guard let a = valueField(tokens[4], key: "a") else { return nil }
        guard let b = valueField(tokens[5], key: "b") else { return nil }

        return TraceEvent(ts: ts, code: code, info: UInt16(info64), pid: UInt32(pid64), a: a, b: b)
    }

    /// `ev=` name to numeric code, the wire-format mirror of `opName` below.
    /// `0x<hex4>` is also accepted so a not-yet-named code still parses
    /// instead of being rejected, keeping the unknown-code reporting alive.
    private static let eventNameToCode: [String: UInt16] = [
        "syscallExit": 0x0100, "ctxSwitch": 0x0200, "idleEnter": 0x0201, "idleExit": 0x0202,
        "ipcBlock": 0x0300, "ipcWake": 0x0301, "ipcTransfer": 0x0302, "preemptSpan": 0x0400,
        "sample": 0x0500, "sampleFrame": 0x0501, "pmuSection": 0x0600, "pmuEvents": 0x0601,
        "bootPhase": 0x0700, "procSpawn": 0x0800, "procName": 0x0801, "procExit": 0x0802, "interactionMark": 0x0900,
    ]

    private static func eventCode(for name: Substring) -> UInt16? {
        if let code = eventNameToCode[String(name)] { return code }
        guard name.hasPrefix("0x") else { return nil }
        let hex = name.dropFirst(2)
        guard hex.count == 4, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return UInt16(hex, radix: 16)
    }

    /// Strips a `key=` prefix off `token`, or `nil` if it is not there.
    private static func rawField(_ token: Substring, key: String) -> Substring? {
        let prefix = key + "="
        guard token.hasPrefix(prefix) else { return nil }
        return token.dropFirst(prefix.count)
    }

    /// A `key=` field that must be plain unsigned decimal: `t`, `pid`,
    /// `info`, `freq`, `lost`, `count` never take the `0x` form.
    private static func decimalField(_ token: Substring, key: String) -> UInt64? {
        rawField(token, key: key).flatMap { UInt64($0) }
    }

    /// A `key=` field that may be decimal or `0x` + lowercase hex, base
    /// picked from the prefix alone: the only two fields this applies to
    /// are `a` and `b`, whatever they mean for the event's class.
    private static func valueField(_ token: Substring, key: String) -> UInt64? {
        guard let raw = rawField(token, key: key) else { return nil }
        guard raw.hasPrefix("0x") else { return UInt64(raw) }
        let hex = raw.dropFirst(2)
        guard !hex.isEmpty, hex.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return UInt64(hex, radix: 16)
    }
}


// MARK: - Naming tables

extension TraceDecoder {

    /// Mirrors `Sources/ReixABI/SyscallNumber.swift` case-by-case (raw value
    /// = declaration index). Keep this in sync by hand when that enum changes.
    ///
    /// It drifted once, silently: five syscalls added after `profileControl`
    /// decoded as `syscall#33` upwards for as long as nobody looked. A name
    /// falling off the end is the only symptom, so a trace showing a numbered
    /// syscall means this list, not the kernel.
    static let syscallNames: [String] = [
        "exit", "yield", "putchar", "getPid", "getParentPid", "parentEndpoint",
        "spawnProcess", "split", "reapChild", "sleep", "terminate",
        "brk", "mmap", "munmap", "decommit",
        "send", "receive", "spawnEndpoint", "call", "reply", "replyRecv",
        "trySend", "tryReceive", "receiveTimeout", "spawnService", "derive",
        "shmCreate", "shmMap",
        "deviceCap", "mapDevice",
        "capExists", "capDrop",
        "profileControl", "procStats",
        "irqWait", "irqAck",
        "dmaAlloc", "dmaPhysical",
    ]

    static func syscallName(_ raw: UInt16) -> String {
        Int(raw) < syscallNames.count ? syscallNames[Int(raw)] : "syscall#\(raw)"
    }

    // Indexed by slot id from PreemptionRegion.swift, which is not declaration order.
    static let regionNames = ["CLON", "UNMP", "DCMT", "TDWN", "RBCK"]

    static func regionName(_ slot: UInt16) -> String {
        Int(slot) < regionNames.count ? regionNames[Int(slot)] : "slot#\(slot)"
    }

    static let phaseNames: [UInt16: String] = [
        1: "ppmReady", 2: "vmmReady", 3: "heapReady", 4: "gicReady", 5: "fsReady",
        6: "pmReady", 7: "schedReady", 8: "ipcReady", 9: "syscallReady",
        10: "timerOn", 11: "firstUser",
    ]

    /// The class/op name for an event code, falling back to hex so codes
    /// added after this table ships still print instead of vanishing.
    static func opName(_ code: UInt16) -> String {
        switch code {
            case 0x0100: return "syscallExit"
            case 0x0200: return "ctxSwitch"
            case 0x0201: return "idleEnter"
            case 0x0202: return "idleExit"
            case 0x0300: return "ipcBlock"
            case 0x0301: return "ipcWake"
            case 0x0302: return "ipcTransfer"
            case 0x0400: return "preemptSpan"
            case 0x0500: return "sample"
            case 0x0501: return "sampleFrame"
            case 0x0600: return "pmuSection"
            case 0x0601: return "pmuEvents"
            case 0x0700: return "bootPhase"
            case 0x0800: return "procSpawn"
            case 0x0801: return "procName"
            case 0x0802: return "procExit"
            case 0x0900: return "interactionMark"
            default:      return "unknown(0x" + String(code, radix: 16) + ")"
        }
    }

    private static let knownCodes: Set<UInt16> = [
        0x0100, 0x0200, 0x0201, 0x0202, 0x0300, 0x0301, 0x0302, 0x0400,
        0x0500, 0x0501, 0x0600, 0x0601, 0x0700, 0x0800, 0x0801, 0x0802, 0x0900,
    ]

    /// `1 = ipcTransfer`, the only section id in use today. Others print as
    /// `section#N` so a newer kernel build still reports instead of vanishing.
    private static let pmuSectionNames: [UInt16: String] = [1: "ipcTransfer"]

    private static func pmuSectionName(_ id: UInt16) -> String {
        pmuSectionNames[id] ?? "section#\(id)"
    }
}


// MARK: - Process names

extension TraceDecoder {

    /// Unpacks a `procName` event's `a`/`b` into the name string, `a` holding
    /// bytes 0-7 little-endian and `b` bytes 8-15, truncated to `length`.
    static func decodeProcName(a: UInt64, b: UInt64, length: UInt16) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)

        var av = a
        for _ in 0..<8 { bytes.append(UInt8(av & 0xFF)); av >>= 8 }
        var bv = b
        for _ in 0..<8 { bytes.append(UInt8(bv & 0xFF)); bv >>= 8 }

        let n = min(Int(length), bytes.count)
        return String(decoding: bytes.prefix(n), as: UTF8.self)
    }

    /// Builds the pid to name map from every `procName` event in the block.
    /// `event.pid` is the named process, not the emitter (see `TraceEvent`).
    static func pidNames(_ block: TraceBlock) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for event in block.events where event.code == 0x0801 {
            names[event.pid] = decodeProcName(a: event.a, b: event.b, length: event.info)
        }
        return names
    }

    /// Raw pid, with the name appended when known. The raw pid always stays
    /// visible, so a trace without any `procName` events reads unchanged.
    private static func pidLabel(_ pid: UInt32, names: [UInt32: String]) -> String {
        guard let name = names[pid] else { return "\(pid)" }
        return "\(pid) (\(name))"
    }
}


// MARK: - Formatting helpers

extension TraceDecoder {

    static func micros(_ counterUnits: UInt64, freq: UInt64) -> Double {
        guard freq > 0 else { return 0 }
        return Double(counterUnits) * 1_000_000.0 / Double(freq)
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Column padding for the tables below: left-justified text by default,
    /// right-justified (`right: true`) for numeric columns.
    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        guard s.count < width else { return s }
        let fill = String(repeating: " ", count: width - s.count)
        return right ? fill + s : s + fill
    }
}


// MARK: - Summary view (default)

extension TraceDecoder {

    private static func printSummary(_ block: TraceBlock) {
        print("Trace summary")
        print("  freq   : \(block.freq) Hz")
        print("  events : \(block.events.count)")
        print("  lost   : \(block.lost)")
        printStacks(block)
        print("")
        printSyscallTable(block)
        print("")
        printIPCStats(block)
        print("")
        printPreemptionSpans(block)
        print("")
        printContextSwitches(block)
        printUnknownCodes(block)
    }

    private struct SyscallStat {
        var name: String
        var n = 0
        var min = Double.infinity
        var max = 0.0
        var total = 0.0
        var avg: Double { n > 0 ? total / Double(n) : 0 }
    }

    private static func printSyscallTable(_ block: TraceBlock) {
        var stats: [UInt16: SyscallStat] = [:]
        for event in block.events where event.code == 0x0100 {
            let us = micros(event.a, freq: block.freq)
            var s = stats[event.info] ?? SyscallStat(name: syscallName(event.info))
            s.n += 1
            s.min = Swift.min(s.min, us)
            s.max = Swift.max(s.max, us)
            s.total += us
            stats[event.info] = s
        }

        print("Syscall latencies (us):")
        guard !stats.isEmpty else { print("  (none)"); return }

        let rows = stats.values.sorted { $0.total > $1.total }
        let nameWidth = max(6, rows.map(\.name.count).max() ?? 6)

        print("  " + pad("NAME", nameWidth) + "  " + pad("N", 4, right: true)
              + "  " + pad("MIN", 10, right: true) + "  " + pad("AVG", 10, right: true)
              + "  " + pad("MAX", 10, right: true) + "  " + pad("TOTAL", 10, right: true))
        for r in rows {
            print("  " + pad(r.name, nameWidth) + "  " + pad(String(r.n), 4, right: true)
                  + "  " + pad(fmt(r.min), 10, right: true) + "  " + pad(fmt(r.avg), 10, right: true)
                  + "  " + pad(fmt(r.max), 10, right: true) + "  " + pad(fmt(r.total), 10, right: true))
        }
    }

    private static func printIPCStats(_ block: TraceBlock) {
        var transfers = 0
        var blocksByReason: [String: Int] = [:]
        var wakes = 0

        for event in block.events {
            switch event.code {
                case 0x0302: transfers += 1
                case 0x0301: wakes += 1
                case 0x0300:
                    let reason: String
                    switch event.info {
                        case 0: reason = "sendQueue"
                        case 1: reason = "recvWait"
                        case 2: reason = "call"
                        default: reason = "unknown(\(event.info))"
                    }
                    blocksByReason[reason, default: 0] += 1
                default: break
            }
        }

        print("IPC:")
        print("  transfers : \(transfers)")
        if blocksByReason.isEmpty {
            print("  blocks    : (none)")
        } else {
            let order = ["sendQueue", "recvWait", "call"]
            let keys = order + blocksByReason.keys.filter { !order.contains($0) }.sorted()
            let parts = keys.compactMap { key in blocksByReason[key].map { "\(key)=\($0)" } }
            print("  blocks    : " + parts.joined(separator: " "))
        }
        print("  wakes     : \(wakes)")
    }

    private struct RegionStat { var count = 0; var maxStretchUs = 0.0; var checkpoints: UInt64 = 0 }

    private static func printPreemptionSpans(_ block: TraceBlock) {
        var stats: [UInt16: RegionStat] = [:]
        for event in block.events where event.code == 0x0400 {
            var s = stats[event.info] ?? RegionStat()
            s.count += 1
            s.maxStretchUs = Swift.max(s.maxStretchUs, micros(event.a, freq: block.freq))
            s.checkpoints += event.b
            stats[event.info] = s
        }

        print("Preemption spans:")
        guard !stats.isEmpty else { print("  (none)"); return }

        print("  " + pad("REGION", 8) + "  " + pad("COUNT", 6, right: true)
              + "  " + pad("MAX_STRETCH(us)", 16, right: true) + "  " + pad("CHECKPOINTS", 12, right: true))
        for slot in stats.keys.sorted() {
            let s = stats[slot]!
            print("  " + pad(regionName(slot), 8) + "  " + pad(String(s.count), 6, right: true)
                  + "  " + pad(fmt(s.maxStretchUs), 16, right: true) + "  " + pad(String(s.checkpoints), 12, right: true))
        }
    }

    private static func printContextSwitches(_ block: TraceBlock) {
        let names = pidNames(block)
        var total = 0
        var idleEnters = 0
        var idleExits = 0
        var activations: [UInt32: Int] = [:]

        for event in block.events {
            switch event.code {
                case 0x0200:
                    total += 1
                    activations[UInt32(truncatingIfNeeded: event.b), default: 0] += 1
                case 0x0201: idleEnters += 1
                case 0x0202: idleExits += 1
                default: break
            }
        }

        print("Context switches:")
        print("  total       : \(total)")
        print("  idle enters : \(idleEnters)")
        print("  idle exits  : \(idleExits)")
        if activations.isEmpty {
            print("  activations : (none)")
        } else {
            print("  activations :")
            for pid in activations.keys.sorted() {
                print("    pid \(pidLabel(pid, names: names)): \(activations[pid]!)")
            }
        }
    }

    /// Codes this decoder does not understand yet, tallied so a newer kernel
    /// build does not silently disappear from the report.
    private static func printUnknownCodes(_ block: TraceBlock) {
        var counts: [UInt16: Int] = [:]
        for event in block.events where !knownCodes.contains(event.code) {
            counts[event.code, default: 0] += 1
        }
        guard !counts.isEmpty else { return }

        print("")
        print("Unknown event codes (not decoded, shown for forward-compat):")
        for code in counts.keys.sorted() {
            print("  0x\(String(code, radix: 16)): \(counts[code]!)")
        }
    }
}


/// The kernel stack figures from the block header, in the one shape both the
/// summary and the boot view print and a post-check can read a field out of.
extension TraceDecoder {

    static func printStacks(_ block: TraceBlock) {
        print("  stack  : kernel \(block.stack) B, exception \(block.exceptionStack) B")
    }
}


// MARK: - Boot view (--boot)

extension TraceDecoder {

    private static func printBoot(_ block: TraceBlock) {
        print("Note: phases before Swift entry (boot.S, MMU trampoline) are not covered by this trace.")
        printStacks(block)
        print("")

        guard let first = block.events.first else { print("(no events)"); return }

        let phases = block.events.filter { $0.code == 0x0700 }
        print("Boot phases:")
        if phases.isEmpty {
            print("  (none)")
        } else {
            print("  " + pad("PHASE", 14) + "  " + pad("T(ms)", 10, right: true) + "  " + pad("DELTA(ms)", 10, right: true))
            var previousTs: UInt64?
            for event in phases {
                let name = phaseNames[event.info] ?? "phase#\(event.info)"
                let absoluteMs = micros(event.ts - first.ts, freq: block.freq) / 1000.0
                let deltaMs = previousTs.map { micros(event.ts - $0, freq: block.freq) / 1000.0 } ?? absoluteMs
                print("  " + pad(name, 14) + "  " + pad(fmt(absoluteMs), 10, right: true) + "  " + pad(fmt(deltaMs), 10, right: true))
                previousTs = event.ts
            }
        }

        print("")
        print("Process events:")
        let names = pidNames(block)
        let procs = block.events.filter { $0.code == 0x0800 || $0.code == 0x0802 }
        if procs.isEmpty {
            print("  (none)")
        } else {
            for event in procs {
                let ms = fmt(micros(event.ts - first.ts, freq: block.freq) / 1000.0)
                if event.code == 0x0800 {
                    let pid    = pidLabel(UInt32(truncatingIfNeeded: event.a), names: names)
                    let parent = pidLabel(UInt32(truncatingIfNeeded: event.b), names: names)
                    print("  t=\(ms)ms  spawn pid=\(pid) parent=\(parent)")
                } else {
                    let pid = pidLabel(UInt32(truncatingIfNeeded: event.a), names: names)
                    print("  t=\(ms)ms  exit  pid=\(pid)")
                }
            }
        }
    }
}


// MARK: - Raw view (--raw)

extension TraceDecoder {

    private static func printRaw(_ block: TraceBlock) {
        guard let first = block.events.first else { print("(no events)"); return }

        for event in block.events {
            let us = fmt(micros(event.ts - first.ts, freq: block.freq))
            print("t=\(us)us  " + pad(opName(event.code), 14) + "  " + describeFields(event, freq: block.freq))
        }
    }

    /// Per-event-class field rendering; anything not in the table above
    /// falls back to the raw info/pid/a/b so an unknown code still prints.
    private static func describeFields(_ event: TraceEvent, freq: UInt64) -> String {
        switch event.code {
            case 0x0100:
                let dur = fmt(micros(event.a, freq: freq))
                return "syscall=\(syscallName(event.info)) pid=\(event.pid) dur=\(dur)us ret=0x\(String(event.b, radix: 16))"
            case 0x0200:
                return "prev=\(event.a) next=\(event.b)"
            case 0x0201, 0x0202:
                return "pid=\(event.pid)"
            case 0x0300:
                let reason: String
                switch event.info {
                    case 0: reason = "sendQueue"
                    case 1: reason = "recvWait"
                    case 2: reason = "call"
                    default: reason = "unknown(\(event.info))"
                }
                return "reason=\(reason) endpoint=\(event.a) pid=\(event.pid)"
            case 0x0301:
                return "woken=\(event.a) pid=\(event.pid)"
            case 0x0302:
                return "sender=\(event.a) receiver=\(event.b)"
            case 0x0400:
                let stretch = fmt(micros(event.a, freq: freq))
                return "region=\(regionName(event.info)) maxStretch=\(stretch)us checkpoints=\(event.b)"
            case 0x0500:
                let el = event.info & 1 != 0 ? "EL1" : "EL0"
                return "elr=0x\(String(event.a, radix: 16)) x30=0x\(String(event.b, radix: 16)) mode=\(el) pid=\(event.pid)"
            case 0x0501:
                return "depth=\(event.info) returnAddr=0x\(String(event.a, radix: 16))"
            case 0x0600:
                return "section=\(pmuSectionName(event.info)) cycles=\(event.a) instructions=\(event.b) (TCG: approximate)"
            case 0x0601:
                return "eventA=\(event.a) eventB=\(event.b) (raw, rare)"
            case 0x0700:
                return "phase=\(phaseNames[event.info] ?? "phase#\(event.info)")"
            case 0x0800:
                return "newPid=\(event.a) parentPid=\(event.b)"
            case 0x0801:
                let name = decodeProcName(a: event.a, b: event.b, length: event.info)
                return "name=\(name) len=\(event.info) pid=\(event.pid)"
            case 0x0802:
                return "pid=\(event.a)"
            case 0x0900:
                let points: [UInt16: String] = [
                    1: "serialDelivered",
                    2: "inputDecoded",
                    3: "shellConsumed",
                    4: "editorCompleted",
                    5: "parserCompleted",
                    6: "presentationRequested",
                    7: "consoleAcknowledged",
                ]
                guard let point = points[event.info], event.a <= UInt64(UInt32.max), event.b <= 0x00FF_FFFF else {
                    return "invalid rawPoint=\(event.info) correlation=\(event.a) value=\(event.b)"
                }
                return "point=\(point) correlation=\(event.a) value=\(event.b)"
            default:
                return "info=0x\(String(event.info, radix: 16)) pid=\(event.pid) a=0x\(String(event.a, radix: 16)) b=0x\(String(event.b, radix: 16))"
        }
    }
}


// MARK: - Profile view (--profile)

extension TraceDecoder {

    private static func printProfile(_ block: TraceBlock, root: URL, arguments: [String]) {
        let names  = pidNames(block)
        let plugin = ReixPlugin()

        printSampleCounts(block, names: names)
        print("")
        printKernelProfile(block, root: root, arguments: arguments, plugin: plugin)
        print("")
        printUserProfile(block, names: names, root: root, arguments: arguments, plugin: plugin)
        print("")
        printPMUSummary(block)
    }


    // MARK: Per-pid sample counts

    private struct PidSampleStat { var el0 = 0; var el1 = 0; var total: Int { el0 + el1 } }

    private static func printSampleCounts(_ block: TraceBlock, names: [UInt32: String]) {
        let samples = block.events.filter { $0.code == 0x0500 }

        var stats: [UInt32: PidSampleStat] = [:]
        for event in samples {
            var s = stats[event.pid] ?? PidSampleStat()
            if event.info & 1 != 0 { s.el1 += 1 } else { s.el0 += 1 }
            stats[event.pid] = s
        }

        // Wall time is the whole block's span, not just the samples' own
        // range: the rate is samples per second of the captured trace.
        let wallSeconds: Double = {
            guard let first = block.events.first, let last = block.events.last, block.freq > 0
            else { return 0 }
            return micros(last.ts - first.ts, freq: block.freq) / 1_000_000.0
        }()
        let rateHz = wallSeconds > 0 ? Double(samples.count) / wallSeconds : 0

        print("Samples: \(samples.count) total, rate=\(fmt(rateHz))/s over \(fmt(wallSeconds * 1000.0))ms wall time")
        print("")
        print("Per-pid sample counts:")
        guard !stats.isEmpty else { print("  (none)"); return }

        let rows = stats.sorted { $0.value.total > $1.value.total }
        let pidWidth = max(4, rows.map { pidLabel($0.key, names: names).count }.max() ?? 4)

        print("  " + pad("PID", pidWidth) + "  " + pad("EL0", 8, right: true)
              + "  " + pad("EL1", 8, right: true) + "  " + pad("TOTAL", 8, right: true))
        for (pid, s) in rows {
            print("  " + pad(pidLabel(pid, names: names), pidWidth) + "  " + pad(String(s.el0), 8, right: true)
                  + "  " + pad(String(s.el1), 8, right: true) + "  " + pad(String(s.total), 8, right: true))
        }
    }


    // MARK: Kernel (EL1) profile

    /// Attaches each `sampleFrame` to the EL1 sample immediately before it:
    /// walking the block in event order, any new sample (EL0 or EL1) closes
    /// whatever EL1 sample was previously open.
    private static func kernelHits(_ block: TraceBlock) -> [(sample: TraceEvent, frames: [TraceEvent])] {
        var hits: [(sample: TraceEvent, frames: [TraceEvent])] = []
        var openIndex: Int?

        for event in block.events {
            switch event.code {
                case 0x0500:
                    if event.info & 1 != 0 {
                        hits.append((event, []))
                        openIndex = hits.count - 1
                    } else {
                        openIndex = nil
                    }
                case 0x0501:
                    if let i = openIndex { hits[i].frames.append(event) }
                default: break
            }
        }
        return hits
    }

    private static func printKernelProfile(
        _ block: TraceBlock, root: URL, arguments: [String], plugin: ReixPlugin
    ) {
        print("Kernel (EL1) profile:")

        let hits = kernelHits(block)
        guard !hits.isEmpty else { print("  (no EL1 samples)"); return }

        // Leaf PC and every caller frame land in the same table: a flat
        // histogram of every address seen while EL1 was interrupted.
        var counts: [UInt64: Int] = [:]
        for hit in hits {
            counts[hit.sample.a, default: 0] += 1
            for frame in hit.frames { counts[frame.a, default: 0] += 1 }
        }

        let top = Array(counts.sorted { $0.value > $1.value }.prefix(10))
        let elf = root.appending(path: plugin.outputDir).appending(path: "kernel.elf")

        printResolvedAddresses(top, elf: elf, arguments: arguments, root: root, plugin: plugin, indent: "  ")
    }


    // MARK: EL0 per-pid profile

    private static func printUserProfile(
        _ block: TraceBlock, names: [UInt32: String], root: URL, arguments: [String], plugin: ReixPlugin
    ) {
        print("EL0 profile by pid:")

        let el0Samples = block.events.filter { $0.code == 0x0500 && $0.info & 1 == 0 }
        guard !el0Samples.isEmpty else { print("  (no EL0 samples)"); return }

        var byPid: [UInt32: [UInt64: Int]] = [:]
        for event in el0Samples {
            byPid[event.pid, default: [:]][event.a, default: 0] += 1
        }

        let pids = byPid.keys.sorted {
            (byPid[$0]?.values.reduce(0, +) ?? 0) > (byPid[$1]?.values.reduce(0, +) ?? 0)
        }

        for pid in pids {
            let counts = byPid[pid]!
            let total  = counts.values.reduce(0, +)
            print("  pid \(pidLabel(pid, names: names)): \(total) sample(s)")

            let top = Array(counts.sorted { $0.value > $1.value }.prefix(10))

            guard let name = names[pid] else {
                print("    (no procName mapping for this pid; showing raw addresses)")
                for (addr, count) in top {
                    print("    0x\(String(addr, radix: 16))  \(count)")
                }
                continue
            }

            // the unstripped ELF the build leaves at .reix/<name> (only the
            // initrd copies under .reix/stripped/ lose their symbols).
            let elf = root.appending(path: plugin.outputDir).appending(path: name)
            printResolvedAddresses(top, elf: elf, arguments: arguments, root: root, plugin: plugin, indent: "    ")
        }
    }


    // MARK: Shared address resolution

    /// Resolves `addresses` (already sorted, highest count first) against
    /// `elf`, sharing `resolvedSymbolizer`/`resolve` with the `symbolize`
    /// subcommand rather than re-walking `PATH` here. Degrades to raw
    /// addresses plus a hint when the symbolizer or the ELF is missing.
    private static func printResolvedAddresses(
        _ addresses: [(key: UInt64, value: Int)],
        elf        : URL,
        arguments  : [String],
        root       : URL,
        plugin     : ReixPlugin,
        indent     : String
    ) {
        func raw() {
            for (addr, count) in addresses {
                print("\(indent)0x\(String(addr, radix: 16))  \(count)")
            }
        }

        let tool = plugin.resolvedSymbolizer(arguments)
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            raw()
            print("\(indent)(no llvm-symbolizer found; point to one with --symbolizer <path>)")
            return
        }

        guard FileManager.default.fileExists(atPath: elf.path) else {
            raw()
            print("\(indent)(no ELF at \(elf.path); build it first)")
            return
        }

        let hexAddresses = addresses.map { "0x" + String($0.key, radix: 16) }
        guard let resolved = try? plugin.resolve(hexAddresses, using: tool, in: elf, cwd: root) else {
            raw()
            print("\(indent)(symbol resolution failed against \(elf.path))")
            return
        }

        for (addr, count) in addresses {
            let key  = "0x" + String(addr, radix: 16)
            let name = resolved[key] ?? "??"
            print("\(indent)" + pad(key, 18) + "  " + pad(String(count), 6, right: true) + "  " + name)
        }
    }


    // MARK: PMU section summary

    private struct PMUStat {
        var count             = 0
        var totalCycles       : UInt64 = 0
        var maxCycles         : UInt64 = 0
        var totalInstructions : UInt64 = 0
        var maxInstructions   : UInt64 = 0
    }

    private static func printPMUSummary(_ block: TraceBlock) {
        var stats: [UInt16: PMUStat] = [:]
        for event in block.events where event.code == 0x0600 {
            var s = stats[event.info] ?? PMUStat()
            s.count += 1
            s.totalCycles += event.a
            s.maxCycles = Swift.max(s.maxCycles, event.a)
            s.totalInstructions += event.b
            s.maxInstructions = Swift.max(s.maxInstructions, event.b)
            stats[event.info] = s
        }

        print("PMU sections (TCG: approximate):")
        guard !stats.isEmpty else { print("  (none)"); return }

        print("  " + pad("SECTION", 12) + "  " + pad("COUNT", 6, right: true)
              + "  " + pad("AVG_CYCLES", 10, right: true) + "  " + pad("MAX_CYCLES", 10, right: true)
              + "  " + pad("AVG_INSTR", 10, right: true) + "  " + pad("MAX_INSTR", 10, right: true))
        for id in stats.keys.sorted() {
            let s = stats[id]!
            let avgCycles = s.count > 0 ? Double(s.totalCycles) / Double(s.count) : 0
            let avgInstr  = s.count > 0 ? Double(s.totalInstructions) / Double(s.count) : 0
            print("  " + pad(pmuSectionName(id), 12) + "  " + pad(String(s.count), 6, right: true)
                  + "  " + pad(fmt(avgCycles), 10, right: true) + "  " + pad(String(s.maxCycles), 10, right: true)
                  + "  " + pad(fmt(avgInstr), 10, right: true) + "  " + pad(String(s.maxInstructions), 10, right: true))
        }
    }
}
