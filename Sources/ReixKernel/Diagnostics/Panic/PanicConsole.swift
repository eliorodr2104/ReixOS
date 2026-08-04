//
//  PanicConsole.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// The panic path's own byte writer: straight to the UART, never through a
/// record.
///
/// The rest of the kernel prints through `LogSink`, which routes every byte
/// on `LogRing.isRecording`. The report cannot use that for the parts it
/// builds a character at a time, for two reasons. The ring is one of the
/// things the report is *dumping*, so feeding it while reading it would be
/// circular; and the machine halts a few instructions after the last line, so
/// anything that lands in the ring is never seen by anybody.
enum PanicConsole {

    // MARK: - Primitives

    @inline(never)
    static func write(_ text: StaticString) { _logger.writeStatic(text) }

    @inline(__always)
    static func put(_ byte: UInt8) { _logger.kputc(byte) }

    @inline(__always)
    static func newline() { _logger.kputc(10) }


    // MARK: - Numbers

    /// Lower-case hex, minimum width, no `0x` prefix: the caller writes the
    /// prefix so it can be omitted inside symbolizer markup.
    @inline(never)
    static func writeHex(_ value: UInt64) {
        guard value != 0 else {
            put(48) // '0'
            return
        }

        var started = false
        var shift   = 60

        while shift >= 0 {
            let nibble = Int((value >> UInt64(shift)) & 0xF)

            if nibble != 0 { started = true }
            if started     { put(nibble < 10 ? UInt8(48 &+ nibble) : UInt8(87 &+ nibble)) }

            shift -= 4
        }
    }


    /// Decimal, optionally zero-padded on the left.
    ///
    /// `LogSink.writeDec` cannot pad, and the fractional part of a timestamp
    /// is meaningless without its leading zeros: `1.000042` printed as
    /// `1.42` is off by three orders of magnitude.
    ///
    /// `width` is in digits and a digit is always one byte, so this counts
    /// what it emits. The label padding in `field` and `rule` cannot, which
    /// is why those two go through `scalarCount`.
    @inline(never)
    static func writeDec(_ value: UInt64, paddedTo width: Int = 0) {
        var divisor: UInt64 = 1
        var digits          = 1

        while value / divisor >= 10 {
            divisor *= 10
            digits  &+= 1
        }

        var padding = width &- digits
        while padding > 0 {
            put(48) // '0'
            padding &-= 1
        }

        var rest = value
        while divisor > 0 {
            put(UInt8(48 &+ (rest / divisor)))

            rest    %= divisor
            divisor /= 10
        }
    }


    /// Renders a raw `CNTVCT_EL0` reading as `seconds.microseconds`.
    ///
    /// The counter is monotonic from reset, so a raw reading is the uptime
    /// and a record's stored reading is the moment that line was written.
    /// The same scale for both is what makes the log tail readable next to
    /// the `Uptime:` line.
    ///
    /// Integer arithmetic only: there is no FPU state to save on this path
    /// and no intention of touching one. `remainder < frequency` keeps the
    /// multiply below 2^63 for any plausible timer.
    @inline(never)
    static func writeSeconds(_ ticks: UInt64) {
        let frequency = Arch.Timer.frequency()

        guard frequency > 0 else {
            write("?")
            return
        }

        writeDec(ticks / frequency)
        put(46) // '.'
        writeDec((ticks % frequency) &* 1_000_000 / frequency, paddedTo: 6)
    }


    // MARK: - Layout

    /// Total width of the report's rules, chosen to match the 80-column
    /// serial terminal the rest of the log is laid out for.
    static let ruleWidth = 54

    /// Column the value of a `Label:` field starts in.
    static let fieldWidth = 11


    /// Number of Unicode scalars in `label`.
    ///
    /// A byte count is wrong the moment a label stops being ASCII: `Größe:`
    /// is 7 bytes and 6 scalars, so byte-padding loses a column, and a longer
    /// multi-byte label drives `remaining` negative, at which point the
    /// `while remaining > 0` loops emit nothing and the column collapses
    /// entirely. Continuation bytes are exactly `10xxxxxx`, so counting the
    /// bytes that are not one counts the scalars.
    ///
    /// - Important: scalars, not display columns. That is the right answer
    ///   for the Latin and symbol text this report realistically carries, and
    ///   deliberately wrong in general: a combining accent is a scalar that
    ///   occupies no column, and a CJK character occupies two. Grapheme
    ///   clustering and East-Asian width need tables this path will never be
    ///   allowed to carry, so they are out of scope rather than pending.
    @inline(__always)
    private static func scalarCount(_ label: StaticString) -> Int {
        var count = 0
        label.withUTF8Buffer { buffer in
            for byte in buffer where (byte & 0xC0) != 0x80 { count &+= 1 }
        }

        return count
    }


    /// Field label, padded so every value in the header block lines up.
    @inline(never)
    static func field(_ label: StaticString) {
        write(label)

        var remaining = fieldWidth &- scalarCount(label)

        while remaining > 0 {
            put(32) // ' '
            remaining &-= 1
        }
    }

    /// Section rule: `-- backtrace -----------------------------------------`.
    ///
    /// Padded programmatically rather than written out as a literal so a
    /// renamed section cannot silently break the alignment of the block.
    @inline(never)
    static func rule(_ label: StaticString) {
        write("-- ")
        write(label)
        put(32) // ' '

        var remaining = ruleWidth &- 4 &- scalarCount(label)

        while remaining > 0 {
            put(45) // '-'
            remaining &-= 1
        }

        newline()
    }
}
