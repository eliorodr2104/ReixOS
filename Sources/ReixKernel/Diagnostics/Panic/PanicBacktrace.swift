//
//  PanicBacktrace.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// Frame-pointer unwinder for the panic report, emitting symbolizer markup
/// beside every raw address.
///
/// The device carries no symbol table, because the kernel's `.symtab` is
/// ~52 KB and that is real money against a 4 MB target, so an address is
/// all it can print. Resolution belongs on the host, and the markup is what
/// lets a host tool do it: `{{{bt:0:0x40081138}}}` is Fuchsia's format,
/// costs nothing on device, and `reix symbolize` rewrites it into a function
/// name and a source line. The raw address stays on the line so the report
/// is still readable without any tooling at all.
///
/// The walk replaced an earlier one on `Arch.CPU` that has since been
/// deleted. Two reasons it could not stay: it numbered nothing, and the
/// markup needs an index per frame; and it looped until it read a zero
/// return address, so a cyclic or corrupt frame chain printed forever with
/// the console as its only output. That is the normal state of affairs after
/// the kind of corruption that gets you here, and a report that never ends
/// is worse than a truncated one. Hence the cap below.
enum PanicBacktrace {

    /// Hard cap on printed frames.
    static let frameLimit = 32


    /// Prints the section, rule included.
    ///
    /// `ELR` and `LR` lead because the exception cut the chain: `x29` at the
    /// moment of the trap points at the frame of the function that faulted,
    /// so its own entry and its caller's return address are not on the chain
    /// and would otherwise be missing from the trace.
    static func emit(_ frame: Arch.TrapFrame) {
        PanicConsole.rule("backtrace")

        var index = 0

        emitFrame(&index, frame.elr, "PC/ELR")
        emitFrame(&index, frame.x30, "LR/x30")

        var framePointer = frame.x29

        while index < frameLimit, isPlausible(framePointer) {
            let returnAddress = word(at: framePointer &+ 8)
            let previous      = word(at: framePointer)

            guard returnAddress != 0 else { break }

            emitFrame(&index, returnAddress, nil)

            // Stacks grow down, so a caller's frame sits above its callee's.
            // Following anything else is how an unwinder hangs on a cycle.
            guard previous > framePointer else { break }

            framePointer = previous
        }

        if index >= frameLimit {
            PanicConsole.write("  (truncated at ")
            PanicConsole.writeDec(UInt64(frameLimit))
            PanicConsole.write(" frames)")
            PanicConsole.newline()
        }
    }


    private static func emitFrame(
        _ index  : inout Int,
        _ address: UInt64,
        _ note   : StaticString?
    ) {
        PanicConsole.write("  #")
        PanicConsole.writeDec(UInt64(index))
        PanicConsole.write(" 0x")
        PanicConsole.writeHex(address)

        PanicConsole.write("  {{{bt:")
        PanicConsole.writeDec(UInt64(index))
        PanicConsole.write(":0x")
        PanicConsole.writeHex(address)
        PanicConsole.write("}}}")

        if let note {
            PanicConsole.write("  ")
            PanicConsole.write(note)
        }

        PanicConsole.newline()

        index &+= 1
    }


    /// Cheapest possible sanity check before dereferencing a frame pointer.
    ///
    /// AAPCS64 keeps the stack, and therefore `x29`, 16-byte aligned, so
    /// anything else in there is garbage and reading through it would fault
    /// inside the printer. This does not make the read safe, it just makes
    /// the obvious cases free; the re-entrancy guard in
    /// `DefaultPanicFormatter` is what covers the rest.
    @inline(__always)
    private static func isPlausible(_ framePointer: UInt64) -> Bool {
        framePointer != 0 && framePointer & 0xF == 0
    }


    @inline(__always)
    private static func word(at address: UInt64) -> UInt64 {
        UnsafePointer<UInt64>(bitPattern: UInt(address))?.pointee ?? 0
    }
}
