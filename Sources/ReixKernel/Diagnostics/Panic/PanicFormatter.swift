//
//  PanicFormatter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Renders a `PanicReport` into a sequence of console lines.
///
/// Stateless by design so it can be swapped at compile time with
/// alternative formatters (e.g. JSON dump over UART, compact one-line
/// report for embedded targets without enough console real estate).
public protocol PanicFormatter {
    static func format(_ report: PanicReport)
}


/// Default human-readable formatter. Layout designed for a 80-column
/// serial terminal, no ANSI escape, no UTF-8.
///
/// The block is ordered by what a reader needs first. It used to open with
/// the trap class, the ESR and an address, so you read three lines of
/// mechanism before finding out what had actually gone wrong; now the
/// description leads, the mechanism follows it, and the register dump sits
/// at the bottom, since nobody reads it until the first four lines have
/// failed to explain things.
///
/// It is delimited on both ends by a fixed marker so a host tool can lift the
/// block out of a terminal capture without guessing where it starts.
///
/// Two properties this file must never lose:
///
/// **Nothing here allocates.** The previous reporter built one of its
/// messages with `"prefix (" + inner + ")"`. That fires when memory has run
/// out, so it asked the exhausted allocator for one more buffer and the
/// kernel died on a nil unwrap *while reporting that it was out of memory*.
/// `StaticString` literals point into `.rodata` and are free; building a
/// `String` is not. The only `String` this file touches is
/// `Kernel.internalPanicMessage`, which was built before the fault and is
/// only ever streamed.
///
/// **A fault inside the report degrades, it does not recurse.** See `depth`.
public struct DefaultPanicFormatter: PanicFormatter {

    /// How many times the panic path has been entered.
    ///
    /// A fault raised *inside* the printer used to re-enter it and recurse
    /// until the stack was gone, so the operator saw an endless spray of
    /// half-reports and never the first one. Depth 1 prints the report;
    /// depth 2 prints a single marker line and returns, letting the caller
    /// halt; depth 3 means the marker itself faulted, so nothing further is
    /// attempted at all.
    ///
    /// Never decremented on purpose: `format` is only ever followed by
    /// `PanicAction.execute()`, so there is no "after" for it to be reset
    /// in, and a formatter that re-armed itself would be one more way to
    /// loop.
    private static var depth = 0


    /// Prints the report, then returns so the caller can halt.
    ///
    /// The first two statements are recovery, not formatting.
    ///
    /// `enterPanicMode` pins the sink write-through and recording-off.
    /// Nothing from here on may sit in the ring, because the next thing this
    /// kernel does is halt and there will be nobody left to drain it, and
    /// nothing may be added to it either, because the log tail below is
    /// *reading* that ring. `.direct` says both things at once.
    ///
    /// `LogRing.end()` closes the record a writer faulted halfway through.
    /// While that record is open `LogSink` sends *everything* into the ring,
    /// so the whole report would have disappeared into the buffer it is
    /// supposed to be dumping. Closing it also patches the real length in, so
    /// the truncated line survives as a complete record and shows up in the
    /// log tail instead of being discarded.
    public static func format(_ report: PanicReport) {
        depth &+= 1

        guard depth == 1 else {
            if depth == 2 { emitNestedMarker(report) }
            return
        }

        LogSink.enterPanicMode()
        LogRing.end()

        // Blank line first: the fault usually lands mid-boot-log and the
        // block has to be visually separable from whatever printed last.
        PanicConsole.newline()

        Self.panic("=== REIX-PANIC BEGIN v1 ===")

        emitReason   (report)
        emitTrap     (report)
        emitAddresses(report)
        emitContext  (report)
        emitUptime   ()

        PanicLogTail.emit()

        if let frame = report.frame {
            PanicBacktrace.emit(frame)
            emitRegisters(frame)
        }

        Self.panic("=== REIX-PANIC END - SYSTEM HALTED ===")
    }


    // MARK: - What happened

    /// The failure description, first line of the report.
    ///
    /// `report.reason` only ever names the exception class, so a deliberate
    /// `internalPanic` arrives here as "Breakpoint", which describes the
    /// instruction and not the fault. The description of the error that
    /// actually caused it is captured into `Kernel.internalPanicMessage`,
    /// and for the whole history of this kernel nothing read it back: every
    /// panic reported the mechanism and discarded the cause.
    ///
    /// It is only trusted for a breakpoint trap. That global is written by
    /// `Kernel.internalPanic` and never cleared, so on any other trap it
    /// holds whatever the last internal error happened to be. Printing that
    /// as the reason for an unrelated kernel abort would replace one
    /// misleading report with another.
    private static func emitReason(_ report: PanicReport) {
        PanicConsole.field("Reason:")

        if report.exception == .breakpoint, let message = Kernel.internalPanicMessage {
            PanicConsole.write(message)
        } else if let reason = report.reason {
            PanicConsole.write(reason)
        } else {
            PanicConsole.write(unattributed)
        }

        PanicConsole.newline()
    }


    /// The mechanism: which trap took the machine down.
    ///
    /// The exception class comes out of `ESR_EL1`, not out of
    /// `Exception.rawValue`, because the two disagree. `Exception.breakpoint`
    /// is spelled `0x32` while the class a `BRK` actually raises is `0x3C`,
    /// so the old header printed a class the architecture does not define.
    /// The register is the authority.
    private static func emitTrap(_ report: PanicReport) {
        let label = report.reason ?? report.exception?.message ?? unclassified

        PanicConsole.field("Trap:")
        PanicConsole.write(label)

        guard let frame = report.frame else {
            PanicConsole.newline()
            return
        }

        PanicConsole.write("  (EC 0x")
        PanicConsole.writeHex((frame.esr >> 26) & 0x3F)
        PanicConsole.write(", ESR 0x")
        PanicConsole.writeHex(frame.esr)
        PanicConsole.write(")")
        PanicConsole.newline()
    }


    private static func emitAddresses(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        PanicConsole.field("Address:")
        PanicConsole.write("PC 0x")
        PanicConsole.writeHex(frame.elr)
        PanicConsole.write("  FAR 0x")
        PanicConsole.writeHex(frame.far)
        PanicConsole.newline()
    }


    /// Where the machine was when it stopped.
    ///
    /// The PID is only printed for a trap taken from EL0, because that is
    /// the only case in which a current process is guaranteed to be
    /// installed. `SPSR.M[3:0] == 0` is the same EL0 test the exception
    /// handler uses. On an EL1 trap the pointer may predate
    /// `setCurrentProcess` entirely, and dereferencing a reset-value
    /// register inside the panic printer is exactly the kind of second fault
    /// this file exists to avoid.
    private static func emitContext(_ report: PanicReport) {
        PanicConsole.field("Context:")
        PanicConsole.write("core 0")

        guard let frame = report.frame else {
            PanicConsole.newline()
            return
        }

        let fromUserSpace = frame.spsr & 0xF == 0

        PanicConsole.write(fromUserSpace ? "  EL0" : "  EL1")

        if let pid = report.pid {
            PanicConsole.write("  pid ")
            PanicConsole.writeDec(pid)

        } else if fromUserSpace, let process = Arch.CPU.getCurrentProcess() {
            PanicConsole.write("  pid ")
            PanicConsole.writeDec(process.pointee.pid)
        }

        PanicConsole.write("  PSTATE 0x")
        PanicConsole.writeHex(frame.spsr)
        PanicConsole.newline()
    }


    /// Wall time since reset.
    ///
    /// Free now that `CNTVCT_EL0` is readable, and it is the difference
    /// between "it died" and "it died 40 ms in, before userland was ever
    /// entered", which for a boot-time fault is most of the diagnosis.
    private static func emitUptime() {
        PanicConsole.field("Uptime:")
        PanicConsole.writeSeconds(Arch.Timer.counter())
        PanicConsole.write(" s")
        PanicConsole.newline()
    }


    // MARK: - State

    private static func emitRegisters(_ frame: Arch.TrapFrame) {
        PanicConsole.rule("registers")

        emitQuad("  x0-x3  : ", frame.x0,  frame.x1,  frame.x2,  frame.x3)
        emitQuad("  x4-x7  : ", frame.x4,  frame.x5,  frame.x6,  frame.x7)
        emitQuad("  x8-x11 : ", frame.x8,  frame.x9,  frame.x10, frame.x11)
        emitQuad("  x12-x15: ", frame.x12, frame.x13, frame.x14, frame.x15)
        emitQuad("  x16-x19: ", frame.x16, frame.x17, frame.x18, frame.x19)
        emitQuad("  x20-x23: ", frame.x20, frame.x21, frame.x22, frame.x23)
        emitQuad("  x24-x27: ", frame.x24, frame.x25, frame.x26, frame.x27)

        PanicConsole.write("  x28-x29: 0x")
        PanicConsole.writeHex(frame.x28)
        PanicConsole.write(" - 0x")
        PanicConsole.writeHex(frame.x29)
        PanicConsole.newline()

        PanicConsole.write("  lr(x30): 0x")
        PanicConsole.writeHex(frame.x30)
        PanicConsole.write("   sp_el0: 0x")
        PanicConsole.writeHex(frame.spel0)
        PanicConsole.newline()
    }


    private static func emitQuad(
        _ label: StaticString,
        _ a    : UInt64,
        _ b    : UInt64,
        _ c    : UInt64,
        _ d    : UInt64
    ) {
        PanicConsole.write(label)

        PanicConsole.write("0x")
        PanicConsole.writeHex(a)
        PanicConsole.write(" - 0x")
        PanicConsole.writeHex(b)
        PanicConsole.write(" - 0x")
        PanicConsole.writeHex(c)
        PanicConsole.write(" - 0x")
        PanicConsole.writeHex(d)

        PanicConsole.newline()
    }


    // MARK: - Degraded path

    /// Everything the second entry is allowed to do.
    ///
    /// Deliberately touches nothing but the UART registers and the trap
    /// frame the caller already has on its stack. In particular it does not
    /// go near `LogRing` (whose cursors the interrupted first report may
    /// have been halfway through moving), `Kernel.internalPanicMessage` (a
    /// heap object, and a corrupt heap is a plausible reason to be here at
    /// all), the frame-pointer chain (the single most likely thing to have
    /// faulted a moment ago) or the register dump.
    private static func emitNestedMarker(_ report: PanicReport) {
        PanicConsole.newline()
        PanicConsole.write("=== REIX-PANIC NESTED - fault inside the panic report ===")
        PanicConsole.newline()

        PanicConsole.write("PC 0x")
        PanicConsole.writeHex(report.frame?.elr ?? 0)
        PanicConsole.write("  FAR 0x")
        PanicConsole.writeHex(report.frame?.far ?? 0)
        PanicConsole.newline()

        PanicConsole.write("=== REIX-PANIC END - SYSTEM HALTED ===")
        PanicConsole.newline()
    }


    private static let unattributed: StaticString = "(the kernel recorded no cause)"
    private static let unclassified: StaticString = "unclassified trap"
}


/// The delimiters go through the sink at `.panic` severity, unlike the body
/// of the report, which is emitted a character at a time by `PanicConsole`.
///
/// That is not inconsistency for its own sake: `LogSink.writesThrough`
/// refuses to buffer `.panic` whatever the mode is, so the two lines that
/// frame the block are guaranteed to reach the wire even if some future
/// change flips the sink back to deferred underneath us, and they arrive
/// tagged, so the block is greppable by severity as well as by marker text.
extension DefaultPanicFormatter: Loggable {
    public static let nameLog : StaticString = "[PNIC]"
    public static let logLevel: LogLevel     = .panic
}
