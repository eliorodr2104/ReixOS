import PackagePlugin
import Foundation

/// Host-side decoder for the kernel's trace ring dump.
///
/// On request the OS prints its trace ring to the serial console, framed
/// like this and interleaved anywhere in a captured boot log (hex is
/// lowercase, unpadded, no `0x`):
///
///     {{{trace:begin:v1:freq=HEX:lost=HEX}}}
///     {{{t:TS:CODE:INFO:PID:A:B}}}      one line per event, oldest first
///     {{{trace:end:count=HEX}}}
///
/// `freq` is CNTFRQ in Hz (62500000 on QEMU virt). TS is the raw 64-bit
/// counter. CODE/INFO are 16-bit, PID is 32-bit, A/B are 64-bit. A log may
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
///   0x07 bootPhase (0x0700): info=phase id
///   0x08 procSpawn (0x0800, a=new pid, b=parent pid), procExit (0x0802, a=pid)
enum TraceDecoder {

    // MARK: - Entry point

    /// `arguments[0]` is the subcommand name ("trace"); the rest is the
    /// logfile path plus an optional `--boot`/`--raw` flag.
    static func run(arguments: [String]) throws {
        let rest = arguments.dropFirst()
        let logPath = rest.first { !$0.hasPrefix("--") }
        let mode: Mode = rest.contains("--boot") ? .boot
            : rest.contains("--raw") ? .raw
            : .summary

        guard let logPath else {
            Diagnostics.error("""
            Usage: swift package reix trace <logfile> [--boot|--raw]
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

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

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
        }
    }

    private enum Mode { case summary, boot, raw }
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
                return "No trace block ({{{trace:begin:...}}} / {{{trace:end:...}}}) found in the log."
            case .truncated(let line):
                return """
                Truncated trace block: 'begin' at line \(line) has no matching 'end'. \
                The capture likely cut off mid-dump.
                """
            }
        }
    }

    private static let eventPattern = #"\{\{\{t:([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9a-fA-F]+)\}\}\}"#
    private static let beginPattern = #"\{\{\{trace:begin:v1:freq=([0-9a-fA-F]+):lost=([0-9a-fA-F]+)\}\}\}"#
    private static let endPattern   = #"\{\{\{trace:end:count=([0-9a-fA-F]+)\}\}\}"#

    /// Scans every line once, tracking the currently open begin/end block. A
    /// fresh begin abandons whatever block was still open (an earlier dump
    /// that never got its end); only the last completed block is returned.
    private static func extractLastBlock(from lines: [String]) throws -> Extraction {
        let eventRegex = try NSRegularExpression(pattern: eventPattern)
        let beginRegex = try NSRegularExpression(pattern: beginPattern)
        let endRegex   = try NSRegularExpression(pattern: endPattern)

        struct OpenBlock { var startLine: Int; var freq: UInt64; var lost: UInt64; var events: [TraceEvent] }

        var open: OpenBlock?
        var completed: [TraceBlock] = []
        var malformed = 0

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = eventRegex.firstMatch(in: line, range: full) {
                guard open != nil else { continue } // an event outside any block: ignore
                if let event = parseEvent(match: m, in: ns) {
                    open?.events.append(event)
                } else {
                    malformed += 1
                }
                continue
            }
            if line.contains("{{{t:") { malformed += 1; continue }

            if let m = beginRegex.firstMatch(in: line, range: full) {
                let freq = UInt64(ns.substring(with: m.range(at: 1)), radix: 16) ?? 0
                let lost = UInt64(ns.substring(with: m.range(at: 2)), radix: 16) ?? 0
                open = OpenBlock(startLine: lineNumber, freq: freq, lost: lost, events: [])
                continue
            }
            if line.contains("{{{trace:begin") { malformed += 1; continue }

            if let m = endRegex.firstMatch(in: line, range: full) {
                guard let current = open else { malformed += 1; continue } // end without begin
                let count = UInt64(ns.substring(with: m.range(at: 1)), radix: 16) ?? 0
                completed.append(TraceBlock(
                    startLine: current.startLine, freq: current.freq, lost: current.lost,
                    endLine: lineNumber, declaredCount: count, events: current.events
                ))
                open = nil
                continue
            }
            if line.contains("{{{trace:end") { malformed += 1; continue }
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

    /// Field width checks double as the malformed-line detector: CODE/INFO
    /// must fit 16 bits and PID must fit 32, or the line is rejected.
    private static func parseEvent(match: NSTextCheckingResult, in ns: NSString) -> TraceEvent? {
        func field(_ i: Int) -> UInt64? { UInt64(ns.substring(with: match.range(at: i)), radix: 16) }

        guard let ts = field(1), let code = field(2), let info = field(3),
              let pid = field(4), let a = field(5), let b = field(6),
              code <= UInt64(UInt16.max), info <= UInt64(UInt16.max), pid <= UInt64(UInt32.max)
        else { return nil }

        return TraceEvent(ts: ts, code: UInt16(code), info: UInt16(info), pid: UInt32(pid), a: a, b: b)
    }
}


// MARK: - Naming tables

extension TraceDecoder {

    /// Mirrors `Sources/ReixABI/SyscallNumber.swift` case-by-case (raw value
    /// = declaration index). Keep this in sync by hand when that enum changes.
    private static let syscallNames: [String] = [
        "exit", "yield", "putchar", "getPid", "getParentPid", "parentEndpoint",
        "spawnProcess", "split", "reapChild", "sleep", "terminate",
        "brk", "mmap", "munmap", "decommit",
        "send", "receive", "spawnEndpoint", "call", "reply", "replyRecv",
        "trySend", "tryReceive", "receiveTimeout", "spawnService", "derive",
        "shmCreate", "shmMap",
        "deviceCap", "mapDevice",
        "capExists", "capDrop", "profileControl",
    ]

    private static func syscallName(_ raw: UInt16) -> String {
        Int(raw) < syscallNames.count ? syscallNames[Int(raw)] : "syscall#\(raw)"
    }

    // Indexed by slot id from PreemptionRegion.swift, which is not declaration order.
    private static let regionNames = ["CLON", "UNMP", "DCMT", "TDWN", "RBCK"]

    private static func regionName(_ slot: UInt16) -> String {
        Int(slot) < regionNames.count ? regionNames[Int(slot)] : "slot#\(slot)"
    }

    private static let phaseNames: [UInt16: String] = [
        1: "ppmReady", 2: "vmmReady", 3: "heapReady", 4: "gicReady", 5: "fsReady",
        6: "pmReady", 7: "schedReady", 8: "ipcReady", 9: "syscallReady",
        10: "timerOn", 11: "firstUser",
    ]

    /// The class/op name for an event code, falling back to hex so codes
    /// added after this table ships still print instead of vanishing.
    private static func opName(_ code: UInt16) -> String {
        switch code {
        case 0x0100: return "syscallExit"
        case 0x0200: return "ctxSwitch"
        case 0x0201: return "idleEnter"
        case 0x0202: return "idleExit"
        case 0x0300: return "ipcBlock"
        case 0x0301: return "ipcWake"
        case 0x0302: return "ipcTransfer"
        case 0x0400: return "preemptSpan"
        case 0x0700: return "bootPhase"
        case 0x0800: return "procSpawn"
        case 0x0802: return "procExit"
        default:      return "unknown(0x" + String(code, radix: 16) + ")"
        }
    }

    private static let knownCodes: Set<UInt16> = [
        0x0100, 0x0200, 0x0201, 0x0202, 0x0300, 0x0301, 0x0302, 0x0400, 0x0700, 0x0800, 0x0802,
    ]
}


// MARK: - Formatting helpers

extension TraceDecoder {

    private static func micros(_ counterUnits: UInt64, freq: UInt64) -> Double {
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
                print("    pid \(pid): \(activations[pid]!)")
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


// MARK: - Boot view (--boot)

extension TraceDecoder {

    private static func printBoot(_ block: TraceBlock) {
        print("Note: phases before Swift entry (boot.S, MMU trampoline) are not covered by this trace.")
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
        let procs = block.events.filter { $0.code == 0x0800 || $0.code == 0x0802 }
        if procs.isEmpty {
            print("  (none)")
        } else {
            for event in procs {
                let ms = fmt(micros(event.ts - first.ts, freq: block.freq) / 1000.0)
                if event.code == 0x0800 {
                    print("  t=\(ms)ms  spawn pid=\(event.a) parent=\(event.b)")
                } else {
                    print("  t=\(ms)ms  exit  pid=\(event.a)")
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
        case 0x0700:
            return "phase=\(phaseNames[event.info] ?? "phase#\(event.info)")"
        case 0x0800:
            return "newPid=\(event.a) parentPid=\(event.b)"
        case 0x0802:
            return "pid=\(event.a)"
        default:
            return "info=0x\(String(event.info, radix: 16)) pid=\(event.pid) a=0x\(String(event.a, radix: 16)) b=0x\(String(event.b, radix: 16))"
        }
    }
}
