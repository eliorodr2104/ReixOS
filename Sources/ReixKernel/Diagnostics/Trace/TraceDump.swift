//
//  TraceDump.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

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
/// order, single ASCII spaces, one record per line, oldest first.
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

    /// Formats the whole ring into the bounded serial transmit queue.
    ///
    /// Race-free without any locking: the only caller is the `profileControl`
    /// provider, which runs in a syscall body with IRQs masked at EL1, so no
    /// emit can run between two of the reads below. This is the invariant
    /// `TraceRing` states, and the only place it has to be honoured by a
    /// reader.
    @inline(never)
    static func toConsole(processManager: UnsafeMutablePointer<ProcessManager>?) -> Bool {
        LogSink.beginTransmission(reserving: terminalReserve)
        LogSink.transmit("[TRACE] begin v=2 freq=")
        LogSink.transmitDec(Arch.Timer.frequency())
        LogSink.transmit(" lost=")
        LogSink.transmitDec(TraceRing.lost)

        // Machine state at dump time, like `lost`: bytes ever written on the
        // two kernel stacks. See `StackUsage` for what the figures do not say.
        LogSink.transmit(" stack=")
        LogSink.transmitDec(StackUsage.kernelStack)
        LogSink.transmit(" exstack=")
        LogSink.transmitDec(StackUsage.exceptionStack)
        LogSink.transmit(10)
        guard LogSink.endTransmission() else { return false }

        var total = 0
        var queued = 0
        var accepting = true

        TraceRing.forEachBootPhase {
            total &+= 1
            guard accepting else { return }
            accepting = writeRecord($0, reserving: terminalReserve)
            if accepting { queued &+= 1 }
        }

        writeLiveNames(
            processManager,
            accepting: &accepting,
            total: &total,
            queued: &queued
        )

        TraceRing.forEachEvent {
            total &+= 1
            guard accepting else { return }
            accepting = writeRecord($0, reserving: terminalReserve)
            if accepting { queued &+= 1 }
        }

        var terminalCommitted = true
        if !accepting {
            terminalCommitted = writeDropNotice(omitted: total &- queued)
        }

        LogSink.beginTransmission()
        LogSink.transmit("[TRACE] end count=")
        LogSink.transmitDec(UInt64(queued))
        LogSink.transmit(10)
        terminalCommitted = LogSink.endTransmission() && terminalCommitted

        return accepting && terminalCommitted
    }


    /// One synthetic `procName` record per live process, stamped now.
    ///
    /// The historical `procName` events are one-shot and the first thing a
    /// busy ring evicts, but the decoder needs pid-to-name whenever the dump
    /// happens, and the names still sit in every `ProcessMetadata`. Replaying
    /// them from there makes the mapping independent of the ring's history.
    private static func writeLiveNames(
        _ processManager: UnsafeMutablePointer<ProcessManager>?,
        accepting: inout Bool,
        total: inout Int,
        queued: inout Int
    ) {
        guard let processManager else { return }

        let now = Arch.Timer.counterUnordered()

        processManager.pointee.forEachProcess { process in
            guard let metadata = process.pointee.metadata else { return }

            total &+= 1
            guard accepting else { return }

            var a: UInt64 = 0
            var b: UInt64 = 0

            for index in 0..<8 {
                a |= UInt64(metadata.pointee.name[index])     << (8 * index)
                b |= UInt64(metadata.pointee.name[index + 8]) << (8 * index)
            }

            accepting = writeRecord(TraceEvent(
                timestamp: now,
                code     : TraceCode.procName,
                info     : UInt16(metadata.pointee.nameLength),
                pid      : UInt32(truncatingIfNeeded: process.pointee.pid),
                a        : a,
                b        : b
            ), reserving: terminalReserve)

            if accepting { queued &+= 1 }
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
            case TraceCode.ipcBlock   : "ipcBlock"
            case TraceCode.ipcWake    : "ipcWake"
            case TraceCode.ipcTransfer: "ipcTransfer"
            case TraceCode.preemptSpan: "preemptSpan"
            case TraceCode.sample     : "sample"
            case TraceCode.sampleFrame: "sampleFrame"
            case TraceCode.pmuSection : "pmuSection"
            case TraceCode.pmuEvents  : "pmuEvents"
            case TraceCode.bootPhase  : "bootPhase"
            case TraceCode.procSpawn  : "procSpawn"
            case TraceCode.procName   : "procName"
            case TraceCode.procExit   : "procExit"
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
