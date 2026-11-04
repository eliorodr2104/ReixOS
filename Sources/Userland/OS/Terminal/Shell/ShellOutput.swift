//
//  ShellOutput.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

enum ShellOutput {

    private static var buffer = ShellOutputBuffer()

    // Asynchronous output uses high-bit sequences so VTAdapter omits it from
    // input-to-screen traces.
    private static var presentationSequence: UInt32 = ReixInteractionSequence.asynchronousBit

    static func begin() { buffer.reset() }

    /// Says what the bytes written inside the body mean.
    ///
    /// The shell never picks a colour: it says `path` or `namespace` and the
    /// backend paints it, the same vocabulary the editor's own line uses.
    static func styled(
        _ role: ReixTextSurfaceStyleRole,
        _ body: () -> Void
    ) {
        let start = buffer.offset
        body()
        buffer.mark(role, from: start, to: buffer.offset)
    }

    @discardableResult
    static func append(_ byte: UInt8) -> Bool {
        buffer.append(byte)
    }

    static var overflowed: Bool { buffer.overflowed }
    static var failed    : Bool { buffer.failed }

    static func invalidate() { buffer.invalidate() }

    @discardableResult
    static func append(_ text: StaticString) -> Bool {
        var complete = true

        for index in 0..<text.utf8CodeUnitCount {
            complete = append(text.utf8Start[index]) && complete
        }

        return complete
    }

    @discardableResult
    static func append(_ text: String) -> Bool {
        var complete = true

        for byte in text.utf8 {
            complete = append(byte) && complete
        }

        return complete
    }

    static func decimal(_ value: UInt64) {
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var number = value
        var count  = 0

        repeat {
            digits[count] = UInt8(ascii: "0") + UInt8(number % 10)
            count  += 1
            number /= 10
        } while number > 0

        while count > 0 {
            count -= 1
            append(digits[count])
        }

    }

    static func flush(
        _ send: (UnsafePointer<UInt8>, Int, UnsafePointer<ReixTextSurfaceStyleSpan>?, Int) -> Bool
    ) -> Bool { buffer.flush(send) }

    /// The next correlation for output the shell emits on its own account.
    static func nextSequence() -> UInt32 {
        presentationSequence = ReixInteractionSequence.nextAsynchronous(
            after: presentationSequence
        )

        return presentationSequence
    }

    static func flush(to terminal: inout InteractionSession) -> Bool {

        flush { source, amount, styles, styleCount in
            terminal.append(
                source,
                count: amount,
                sequence: nextSequence(),
                styles: styles,
                styleCount: styleCount
            )
        }
    }

    static func flushDiagnostic(to terminal: inout InteractionSession) -> Bool {
        flush { source, amount, _, _ in
            terminal.appendDiagnostic(source, count: amount, sequence: nextSequence())
        }
    }
}

func print(
    _ value     : StaticString,
      terminator: StaticString = "\n"
) {
    ShellOutput.append(value)
    ShellOutput.append(terminator)
}

func print(
    _ value     : String,
      terminator: StaticString = "\n"
) {
    ShellOutput.append(value)
    ShellOutput.append(terminator)
}

func putchar(ch: UInt8) { ShellOutput.append(ch) }

func printDec(
    _ value     : UInt64,
      terminator: StaticString = "\n"
) {
    ShellOutput.decimal(value)
    ShellOutput.append(terminator)
}

func printDecPadded(
    _ value: UInt64,
      width: Int
) {
    var digits = InlineArray<20, UInt8>(repeating: 0)
    var number = value
    var count  = 0

    repeat {
        digits[count] = UInt8(ascii: "0") + UInt8(number % 10)
        count += 1
        number /= 10
    } while number > 0

    var spaces = width - count

    while spaces > 0 {
        ShellOutput.append(UInt8(ascii: " "))
        spaces -= 1
    }

    while count > 0 {
        count -= 1
        ShellOutput.append(digits[count])
    }
}

func printPadded(
    _ value: UnsafePointer<UInt8>,
      count: Int,
      width: Int
) {
    guard count >= 0 else { return }

    for index in 0..<count { ShellOutput.append(value[index]) }

    var spaces = width - count
    while spaces > 0 { ShellOutput.append(UInt8(ascii: " ")); spaces -= 1 }
}
