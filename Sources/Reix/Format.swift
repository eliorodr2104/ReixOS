//
//  Format.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


/// Digits needed for the largest `UInt64` in decimal, `UInt64.max`.
private let maxDecDigits = 20

@inline(__always)
private func decDigit(_ value: UInt64) -> UInt8 {
    UInt8(ascii: "0") + UInt8(value)
}

@inline(__always)
private func hexDigit(_ value: UInt64) -> UInt8 {
    value < 10 ? UInt8(ascii: "0") + UInt8(value) : UInt8(ascii: "a") + UInt8(value - 10)
}

/// Reverses the first `count` bytes of `buffer` in place.
///
/// `writeDec` and `writeHex` both emit least-significant-digit first, so the
/// run has to be flipped before it reads as an ordinary number.
private func reverse(
    _ buffer: UnsafeMutableBufferPointer<UInt8>,
      count : Int
) {

    var i = 0
    var j = count - 1

    while i < j {
        let tmp   = buffer[i]
        buffer[i] = buffer[j]
        buffer[j] = tmp
        i += 1
        j -= 1
    }
}

/// Writes `value` as ASCII decimal into `buffer`, most significant digit
/// first, no sign and no terminator.
///
/// `buffer` must hold at least 20 bytes, the width of `UInt64.max`. Returns
/// the number of bytes written.
@discardableResult
public func writeDec(
    _    value : UInt64,
    into buffer: UnsafeMutableBufferPointer<UInt8>
) -> Int {

    if value == 0 {
        buffer[0] = UInt8(ascii: "0")
        return 1
    }

    var remaining = value
    var count     = 0

    while remaining > 0 {
        buffer[count] = decDigit(remaining % 10)
        remaining    /= 10
        count        += 1
    }

    reverse(buffer, count: count)
    return count
}

/// Writes `value` as lowercase ASCII hex into `buffer`, most significant
/// digit first, no `0x` prefix and no terminator.
///
/// `buffer` must hold at least 16 bytes, the width of `UInt64.max`. Returns
/// the number of bytes written.
@discardableResult
public func writeHex(
    _    value : UInt64,
    into buffer: UnsafeMutableBufferPointer<UInt8>
) -> Int {

    if value == 0 {
        buffer[0] = UInt8(ascii: "0")
        return 1
    }

    var remaining = value
    var count     = 0

    while remaining > 0 {
        buffer[count] = hexDigit(remaining & 0xF)
        remaining   >>= 4
        count        += 1
    }

    reverse(buffer, count: count)
    return count
}

/// Prints `value` in decimal, followed by `terminator`, without ever
/// building a `String`.
///
/// Formats into a fixed stack buffer and emits byte by byte through
/// `putchar`, the same sink `print` uses under the console client.
public func printDec(
    _ value     : UInt64,
      terminator: StaticString = "\n"
) {

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: maxDecDigits) { buffer in
        let count = writeDec(value, into: buffer)

        for i in 0..<count {
            putchar(ch: buffer[i])
        }
    }

    let term = terminator.utf8Start
    for i in 0..<terminator.utf8CodeUnitCount {
        putchar(ch: term[i])
    }
}
