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
    // Asynchronous shell output has no one-to-one input correlation. Reserve
    // the high-bit sequence namespace so TerminalServer can leave it out of
    // key-to-screen interaction traces instead of creating duplicate points.
    private static var presentationSequence: UInt32 = ReixTerminalTransport.asynchronousSequenceBit

    static func begin() { buffer.reset() }

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
        for index in 0..<text.utf8CodeUnitCount { complete = append(text.utf8Start[index]) && complete }
        return complete
    }

    @discardableResult
    static func append(_ text: String) -> Bool {
        var complete = true
        for byte in text.utf8 { complete = append(byte) && complete }
        return complete
    }

    static func decimal(_ value: UInt64) {
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var number = value
        var count  = 0
        repeat {
            digits[count] = UInt8(ascii: "0") + UInt8(number % 10)
            count += 1
            number /= 10
        } while number > 0
        while count > 0 {
            count -= 1
            append(digits[count])
        }
    }

    static func flush(_ send: (UnsafePointer<UInt8>, Int) -> Bool) -> Bool {
        buffer.flush(send)
    }

    static func flush(to terminal: inout Terminal) -> Bool {
        flush { source, amount in
            presentationSequence = ReixTerminalTransport.nextAsynchronousSequence(after: presentationSequence)
            guard let command = ReixTextSurfaceCommand(
                kind: .insert,
                sequence: presentationSequence,
                bytes: source,
                count: amount
            ) else { return false }
            return terminal.present(command)
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
    while spaces > 0 { ShellOutput.append(UInt8(ascii: " ")); spaces -= 1 }
    while count > 0 { count -= 1; ShellOutput.append(digits[count]) }
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
