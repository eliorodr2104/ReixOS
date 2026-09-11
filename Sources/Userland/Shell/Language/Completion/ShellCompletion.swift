//
//  ShellCompletion.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What kind of thing a candidate is, which is also how it is drawn.
public enum ShellCompletionKind: UInt8, Equatable {
    case namespace
    case command
    case label
    case member
    case method
    case variable
    case keyword
    case operatorSymbol
    case path
}

/// One thing that would fit where the cursor is.
///
/// The name is carried as bytes rather than as a span, because a candidate
/// outlives the reading it came from: a receiver's name is in the catalog, a
/// binding's name is in the line, and a path's name will come from a disk.
public struct ShellCompletion {
    public static let nameCapacity = 32

    public let kind : ShellCompletionKind
    public private(set) var name  = InlineArray<32, UInt8>(repeating: 0)
    public private(set) var count = 0

    /// What to write after the name so the line reads as it should: `.` after
    /// a receiver, `: ` after a label, ` { }` after a method that takes a
    /// closure, nothing otherwise.
    public let suffix : StaticString

    /// How far back from the end of what was written the cursor belongs, so
    /// accepting `filter` leaves it inside the braces rather than after them.
    public let caret  : Int

    /// The shape of the thing, for the column beside the name.
    public let detail : StaticString

    /// One line about it, in the words of whoever documented it.
    public let summary: StaticString

    /// Changes something a later command cannot put back.
    public let sensitive: Bool

    /// Which band this sits in when the list is ordered. Lower comes first,
    /// and the bands are what the context makes of a kind: after a value's
    /// dot its own members come before the methods every value answers.
    public let rank: UInt8

    public init?(
        kind     : ShellCompletionKind,
        name     : StaticString,
        suffix   : StaticString = "",
        detail   : StaticString = "",
        summary  : StaticString = "",
        sensitive: Bool = false,
        rank     : UInt8 = 1,
        caret    : Int = 0
    ) {
        guard name.utf8CodeUnitCount > 0, name.utf8CodeUnitCount <= Self.nameCapacity else { return nil }
        self.kind = kind
        self.suffix = suffix
        self.caret = caret
        self.detail = detail
        self.summary = summary
        self.sensitive = sensitive
        self.rank = rank
        for index in 0..<name.utf8CodeUnitCount { self.name[index] = name.utf8Start[index] }
        self.count = name.utf8CodeUnitCount
    }

    /// A candidate read out of the line itself, such as a binding.
    public init?(
        kind     : ShellCompletionKind,
        bytes    : UnsafePointer<UInt8>,
        count    : Int,
        suffix   : StaticString = "",
        detail   : StaticString = "",
        summary  : StaticString = "",
        sensitive: Bool = false,
        rank     : UInt8 = 1,
        caret    : Int = 0
    ) {
        guard count > 0, count <= Self.nameCapacity else { return nil }
        self.kind = kind
        self.suffix = suffix
        self.caret = caret
        self.detail = detail
        self.summary = summary
        self.sensitive = sensitive
        self.rank = rank
        for index in 0..<count { self.name[index] = bytes[index] }
        self.count = count
    }

    public func withName<Result>(_ body: (UnsafePointer<UInt8>, Int) -> Result) -> Result {
        var storage = name
        return storage.span.withUnsafeBufferPointer { body($0.baseAddress!, count) }
    }
}
