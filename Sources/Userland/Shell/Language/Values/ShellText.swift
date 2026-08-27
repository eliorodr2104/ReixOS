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

    public static func < (lhs: ShellText, rhs: ShellText) -> Bool {
        let common = lhs.count < rhs.count ? lhs.count : rhs.count
        for index in 0..<common {
            if lhs.storage[index] != rhs.storage[index] {
                return lhs.storage[index] < rhs.storage[index]
            }
        }
        return lhs.count < rhs.count
    }
}
