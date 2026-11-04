//
//  ShellText.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct ShellText: Equatable {
    public static let capacity = 128
    private var storage        = InlineArray<128, UInt8>(repeating: 0)
    public private(set) var count = 0

    public init() {}

    public init?(
        _ source: UnsafePointer<UInt8>,
          count : Int
    ) {
        guard count >= 0, count <= Self.capacity else { return nil }
        for index in 0..<count { storage[index] = source[index] }
        self.count = count
    }

    public init?(_ source: StaticString) {
        self.init(source.utf8Start, count: source.utf8CodeUnitCount)
    }

    public func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    public func withBytes<Result>(_ body: (UnsafePointer<UInt8>, Int) -> Result) -> Result {
        storage.span.withUnsafeBufferPointer { body($0.baseAddress!, count) }
    }

    public func equals(_ source: StaticString) -> Bool {
        guard count == source.utf8CodeUnitCount else { return false }
        for index in 0..<count where storage[index] != source.utf8Start[index] { return false }
        return true
    }

    public static func == (lhs: ShellText, rhs: ShellText) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }

    public func contains(_ needle: ShellText) -> Bool {
        guard needle.count > 0 else { return true }
        guard needle.count <= count else { return false }
        var start = 0
        while start <= count - needle.count {
            var matched = true
            for offset in 0..<needle.count where storage[start + offset] != needle.storage[offset] {
                matched = false
                break
            }
            if matched { return true }
            start += 1
        }
        return false
    }

    /// Whether this begins, or ends, with `part`.
    ///
    /// One function for both because they are the same walk from opposite
    /// ends, and two would be two places to get the bounds wrong.
    public func begins(
        with part: ShellText,
        atFront  : Bool
    ) -> Bool {
        guard part.count > 0 else { return true }
        guard part.count <= count else { return false }
        let start = atFront ? 0 : count - part.count
        for offset in 0..<part.count where storage[start + offset] != part.storage[offset] {
            return false
        }
        return true
    }

    /// Immutable string operations keep the value inside the same explicit
    /// 128-byte budget as every other shell String.
    public func appending(_ other: ShellText) -> ShellText? {
        guard count <= Self.capacity - other.count else { return nil }
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        for index in 0..<count { bytes[index] = storage[index] }
        for index in 0..<other.count { bytes[count + index] = other.storage[index] }
        return bytes.span.withUnsafeBufferPointer {
            ShellText($0.baseAddress!, count: count + other.count)
        }
    }

    /// Reix's first case transform is deliberately ASCII-only: non-ASCII
    /// UTF-8 bytes are preserved byte-for-byte instead of being corrupted by
    /// an incomplete Unicode mapping.
    public func changingASCIICase(uppercased: Bool) -> ShellText {
        var answer = self
        for index in 0..<count {
            let byte = answer.storage[index]
            if uppercased, byte >= 0x61, byte <= 0x7A {
                answer.storage[index] = byte - 0x20
            } else if !uppercased, byte >= 0x41, byte <= 0x5A {
                answer.storage[index] = byte + 0x20
            }
        }
        return answer
    }

    public func trimmingASCIIWhitespace() -> ShellText {
        var first = 0
        var last = count
        while first < last, Self.isASCIIWhitespace(storage[first]) { first += 1 }
        while last > first, Self.isASCIIWhitespace(storage[last - 1]) { last -= 1 }
        return storage.span.withUnsafeBufferPointer {
            ShellText($0.baseAddress!.advanced(by: first), count: last - first)!
        }
    }

    public static func < (lhs: ShellText, rhs: ShellText) -> Bool {
        let common = lhs.count < rhs.count ? lhs.count : rhs.count
        for index in 0..<common {
            if lhs.storage[index] != rhs.storage[index] {
                return lhs.storage[index] < rhs.storage[index]
            }
        }
        return lhs.count < rhs.count
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
