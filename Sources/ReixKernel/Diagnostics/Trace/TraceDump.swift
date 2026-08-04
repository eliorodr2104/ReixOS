//
//  TraceDump.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Writes the ring out in the one format the host decoder parses.
///
/// Straight to the UART through `PanicConsole`, never through `LogRing`, for
/// two of the three reasons the panic report has: the sink would interleave
/// framed log records into the middle of a trace record, and a dump that landed
/// in the ring would be drained by the timer tick long after the tool asking
/// for it had given up. Borrowing `PanicConsole` entangles nothing, its
/// primitives are `_logger.kputc` and a hex writer and they touch no panic
/// state.
///
/// The framing is a contract, not a layout choice:
///
///     {{{trace:begin:v1:freq=HEX:lost=HEX}}}
///     {{{t:TS:CODE:INFO:PID:A:B}}}
///     {{{trace:end:count=HEX}}}
///
/// Lower-case hex throughout, no `0x`, no padding, one record per line oldest
/// first. The braces are what let the decoder pick these lines out of a console
/// that is still carrying the ordinary log.
enum TraceDump {

    /// Walks the whole ring onto the console.
    ///
    /// Race-free without any locking: the only caller is the `profileControl`
    /// provider, which runs in a syscall body with IRQs masked at EL1, so no
    /// emit can run between two of the reads below. This is the invariant
    /// `TraceRing` states, and the only place it has to be honoured by a
    /// reader.
    @inline(never)
    static func toConsole() {
        PanicConsole.write("{{{trace:begin:v1:freq=")
        PanicConsole.writeHex(Arch.Timer.frequency())
        PanicConsole.write(":lost=")
        PanicConsole.writeHex(TraceRing.lost)
        PanicConsole.write("}}}")
        PanicConsole.newline()

        // Boot phases live outside the ring so eviction cannot reach them.
        // They are the oldest stamps, so replaying them first keeps the order.
        let phases  = TraceRing.forEachBootPhase { writeRecord($0) }
        let visited = TraceRing.forEachEvent     { writeRecord($0) }

        PanicConsole.write("{{{trace:end:count=")
        PanicConsole.writeHex(UInt64(phases + visited))
        PanicConsole.write("}}}")
        PanicConsole.newline()
    }


    private static func writeRecord(_ event: TraceEvent) {
        PanicConsole.write("{{{t:")
        PanicConsole.writeHex(event.timestamp)
        separator()
        PanicConsole.writeHex(UInt64(event.code))
        separator()
        PanicConsole.writeHex(UInt64(event.info))
        separator()
        PanicConsole.writeHex(UInt64(event.pid))
        separator()
        PanicConsole.writeHex(event.a)
        separator()
        PanicConsole.writeHex(event.b)
        PanicConsole.write("}}}")
        PanicConsole.newline()
    }


    @inline(__always)
    private static func separator() {
        PanicConsole.put(58) // ':'
    }
}
