//
//  TraceDump.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

import ReixABI

/// Writes the ring out in the one format the host decoder parses.
///
/// Each line is committed atomically to the bounded serial transmit queue.
/// The timer IRQ only drains a fixed byte budget and never formats a dump.
///
/// The framing is a contract, not a layout choice:
///
///     [TRACE] begin v=2 freq=<dec> lost=<dec> stack=<dec> exstack=<dec>
///     [TRACE] t=<dec> ev=<name> pid=<dec> info=<dec> a=<val> b=<val>
///     [TRACE] end count=<dec>
///
/// `<dec>` is an unsigned decimal, no leading zeros, plain `0` for zero.
/// `<val>` is decimal too, except the address-like fields below, which print
/// as `0x` plus lowercase unpadded hex. `ev` is the event's name, looked up
/// in `name(of:)`; a code with no entry prints `0x` and its four hex digits
/// instead of a name. Every field is present on every record, in this exact
/// order, single ASCII spaces, one record per line, ring history oldest first.
///
/// Address-like fields, hex instead of decimal:
/// - `sample`:      `a` and `b` (PC and x30).
/// - `sampleFrame`: `a` (the return address).
/// - `ipcBlock`:    `a` (the endpoint address).
/// - `procName`:    `a` and `b` (packed name bytes, meaningless as decimal).
///
/// `info` and `pid` are always decimal, and so are `t`, `freq`, `lost` and
/// `count`.
///
/// - Important: byte-exact contract with the host decoder. A new event code
///   needs a case in `name(of:)` below and stays in step with `TraceCode` in
///   `Events/TraceCode.swift`.
enum TraceDump {
    private static let terminalReserve = 128

    /// One fixed ring interval, formatted and drained with windows between
    /// complete lines. No task switch is allowed while the transcript is open.
    @inline(never)
    static func toConsole(processManager: UnsafeMutablePointer<ProcessManager>?) -> Bool {
        guard let snapshot = TraceRing.protectSnapshot() else { return false }
        defer { snapshot.release() }
        var complete = false
        withUnsafeMutablePointer(to: &complete) { result in
            _ = Preemption.run(TraceConsoleDump.self, ConsoleDump(
                snapshot: snapshot,
                includeNames: processManager != nil,
                result: result
            ))
        }
        return complete
    }

    /// The timer may emit, evict, export, wake sleepers and drain serial bytes
    /// between steps. Every step closes its line before any of that can run.
    /// The kernel watermark scan stays atomic: a timer can dirty already-scanned
    /// poison and otherwise make the scan miss the deepest stack write.
    private struct ConsoleDump: ResumableOperation {
        typealias Failure = Never

        let includeNames: Bool
        let result: UnsafeMutablePointer<Bool>
        private var snapshot: TraceRing.Snapshot
        private let irqMaxima = IrqOffStretch.snapshot()
        private var irqIndex = 0
        private let timestamp = Arch.Timer.counterUnordered()
        private var phase = -2
        private var kernelStack: UInt64 = 0
        private var exceptionStack: UInt64 = 0
        private var bootIndex = 0
        private var nameCursor: PID = 0
        private var total = 0
        private var queued = 0
        private var accepting = true
        private var drainRemaining = SerialTransmitQueue.capacity

        init(snapshot: TraceRing.Snapshot, includeNames: Bool, result: UnsafeMutablePointer<Bool>) {
            self.snapshot = snapshot
            self.includeNames = includeNames
            self.result = result
            total = snapshot.remaining
        }

        mutating func step() -> Progress {
            if phase < 5, accepting, LogSink.transmissionAvailable < 512,
               LogSink.drain(budget: LogSink.tickBudget) > 0 { return .more }

            switch phase {
                case -2:
                    kernelStack = StackUsage.kernelStack
                    phase = -1

                case -1:
                    exceptionStack = StackUsage.exceptionStack
                    phase = 0

                case 0:
                    LogSink.beginTransmission(reserving: terminalReserve)
                    LogSink.transmit("[TRACE] begin v=2 freq=")
                    LogSink.transmitDec(Arch.Timer.frequency())
                    LogSink.transmit(" lost=")
                    LogSink.transmitDec(snapshot.lost)
                    LogSink.transmit(" stack=")
                    LogSink.transmitDec(kernelStack)
                    LogSink.transmit(" exstack=")
                    LogSink.transmitDec(exceptionStack)
                    LogSink.transmit(10)
                    guard LogSink.endTransmission() else { return .done }
                    phase = 1

                case 1:
                    if bootIndex < 12 {
                        if let event = TraceRing.bootPhase(at: bootIndex) { write(event) }
                        bootIndex += 1
                    } else { phase = 2 }

                case 2:
                    if includeNames, let process = ProcessStatsIndex.successor(after: nameCursor) {
                        nameCursor = process.pointee.pid
                        if let metadata = process.pointee.metadata {
                            var a: UInt64 = 0
                            var b: UInt64 = 0
                            for index in 0..<8 {
                                a |= UInt64(metadata.pointee.name[index]) << (8 * index)
                                b |= UInt64(metadata.pointee.name[index + 8]) << (8 * index)
                            }
                            write(TraceEvent(
                                timestamp: timestamp,
                                code: TraceCode.procName,
                                info: UInt16(metadata.pointee.nameLength),
                                pid: UInt32(truncatingIfNeeded: process.pointee.pid),
                                a: a, b: b
                            ))
                        }
                    } else { phase = 3 }

                case 3:
                    if irqIndex < IrqOffPath.count {
                        let maximum = irqMaxima[irqIndex]
                        if maximum != 0 {
                            write(TraceEvent(timestamp: timestamp, code: TraceCode.irqOff,
                                info: UInt16(irqIndex), a: UInt64(maximum)))
                        }
                        irqIndex += 1
                    } else { phase = 4 }

                case 4:
                    if accepting, let event = snapshot.next() {
                        accepting = writeRecord(event, reserving: terminalReserve)
                        if accepting { queued += 1 }
                    } else {
                        accepting = accepting && !snapshot.invalidated
                        snapshot.release()
                        phase = 5
                    }

                case 5:
                    var terminalCommitted = true
                    if !accepting { terminalCommitted = writeDropNotice(omitted: total - queued) }
                    LogSink.beginTransmission()
                    LogSink.transmit("[TRACE] end count=")
                    LogSink.transmitDec(UInt64(queued))
                    LogSink.transmit(10)
                    terminalCommitted = LogSink.endTransmission() && terminalCommitted
                    result.pointee = accepting && terminalCommitted
                    phase = 6

                default:
                    guard drainRemaining > 0 else { return .done }
                    let sent = LogSink.drain(budget: min(LogSink.tickBudget, drainRemaining))
                    drainRemaining -= sent
                    if sent == 0 { return .done }
            }
            return .more
        }

        private mutating func write(_ event: TraceEvent) {
            total += 1
            guard accepting else { return }
            accepting = writeRecord(event, reserving: terminalReserve)
            if accepting { queued += 1 }
        }
    }


    /// One `[TRACE] t=... ev=... pid=... info=... a=... b=...` line.
    private static func writeRecord(
        _ event: TraceEvent,
        reserving reservedBytes: Int
    ) -> Bool {
        let hex = hexFields(for: event.code)

        LogSink.beginTransmission(reserving: reservedBytes)
        LogSink.transmit("[TRACE] t=")
        LogSink.transmitDec(event.timestamp)
        LogSink.transmit(" ev=")
        writeEventName(event.code)
        LogSink.transmit(" pid=")
        LogSink.transmitDec(UInt64(event.pid))
        LogSink.transmit(" info=")
        LogSink.transmitDec(UInt64(event.info))
        LogSink.transmit(" a=")
        writeValue(event.a, hex: hex.a)
        LogSink.transmit(" b=")
        writeValue(event.b, hex: hex.b)
        LogSink.transmit(10)
        return LogSink.endTransmission()
    }


    private static func writeDropNotice(omitted: Int) -> Bool {
        LogSink.beginTransmission()
        LogSink.transmit("[TRACE-DROP] omitted=")
        LogSink.transmitDec(UInt64(omitted))
        LogSink.transmit(10)
        return LogSink.endTransmission()
    }


    /// `ev=`'s payload: the name table's entry, or a raw code for whatever
    /// is not in it yet.
    @inline(never)
    private static func writeEventName(_ code: UInt16) {
        
        if let known = name(of: code) {
            LogSink.transmit(known)
            
        } else {
            LogSink.transmit("0x")
            writeHex4(code)
        }
        
    }


    /// `a=`/`b=`'s payload: `0x` hex for an address-like field, plain
    /// decimal for everything else.
    @inline(__always)
    private static func writeValue(_ value: UInt64, hex: Bool) {
        
        if hex {
            LogSink.transmit("0x")
            LogSink.transmitHex(value)
            
        } else { LogSink.transmitDec(value) }
        
    }


    /// The event vocabulary's names, kept in sync with `TraceCode` in
    /// `Events/TraceCode.swift` and with the host decoder's own table.
    private static func name(of code: UInt16) -> StaticString? {
        
        switch code {
            case TraceCode.syscallExit: "syscallExit"
            case TraceCode.ctxSwitch  : "ctxSwitch"
            case TraceCode.idleEnter  : "idleEnter"
            case TraceCode.idleExit   : "idleExit"
            case TraceCode.wakeRun    : "wakeRun"
            case TraceCode.deadlineLag: "deadlineLag"
            case TraceCode.ipcBlock   : "ipcBlock"
            case TraceCode.ipcWake    : "ipcWake"
            case TraceCode.ipcTransfer: "ipcTransfer"
            case TraceCode.preemptSpan: "preemptSpan"
            case TraceCode.irqOff     : "irqOff"
            case TraceCode.sample     : "sample"
            case TraceCode.sampleFrame: "sampleFrame"
            case TraceCode.pmuSection : "pmuSection"
            case TraceCode.pmuEvents  : "pmuEvents"
            case TraceCode.bootPhase  : "bootPhase"
            case TraceCode.procSpawn  : "procSpawn"
            case TraceCode.procName   : "procName"
            case TraceCode.procExit   : "procExit"
            case TraceCode.interactionMark: "interactionMark"
            default                   : nil
        }
        
    }


    /// Whether `a` and `b` are address-like for `code`, per the table in
    /// this file's doc comment.
    private static func hexFields(for code: UInt16) -> (a: Bool, b: Bool) {
        switch code {
            case TraceCode.sample     : (true , true )
            case TraceCode.sampleFrame: (true , false)
            case TraceCode.ipcBlock   : (true , false)
            case TraceCode.procName   : (true , true )
            default                   : (false, false)
        }
    }


    /// Four lowercase hex digits, zero-padded, no `0x` prefix.
    ///
    /// The only caller needing padding is the unknown-code fallback: every
    /// named code already prints as a string, so `transmitHex`
    /// covers the address-like fields without it.
    @inline(never)
    private static func writeHex4(_ value: UInt16) {
        var shift = 12

        while shift >= 0 {
            let nibble = Int((value >> UInt16(shift)) & 0xF)
            LogSink.transmit(nibble < 10 ? UInt8(48 &+ nibble) : UInt8(87 &+ nibble))
            shift -= 4
        }
    }
}
