//
//  ShellCompletionSet.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// The best few candidates, in an order that does not depend on the weather.
///
/// Bounded on purpose: an editor that offers everything offers nothing, and a
/// list that grows with the catalog is a list somebody has to allocate. What
/// did not fit is counted, not forgotten, so the popup can say there is more.
public struct ShellCompletionSet {
    public static let capacity = 8

    private var entries = InlineArray<8, ShellCompletion?>(repeating: nil)

    public private(set) var count   = 0

    /// How many candidates matched in all, including the ones that did not fit.
    public private(set) var matched = 0

    public init() {}

    public var truncated: Bool { matched > count }

    public func candidate(at index: Int) -> ShellCompletion? {
        guard index >= 0, index < count else { return nil }
        return entries[index]
    }

    /// Places a candidate in rank order, dropping the worst when full.
    ///
    /// Band first, then shorter, then alphabetical. Nothing here consults
    /// time, memory addresses or insertion order, so the same line always
    /// offers the same list in the same order.
    internal mutating func insert(_ candidate: ShellCompletion) {
        matched += 1
        var position = count
        while position > 0, let existing = entries[position - 1],
              Self.precedes(candidate, existing) {
            if position < entries.count { entries[position] = existing }
            position -= 1
        }
        guard position < entries.count else { return }
        entries[position] = candidate
        if count < entries.count { count += 1 }
    }

    internal static func precedes(
        _ left : ShellCompletion,
        _ right: ShellCompletion
    ) -> Bool {
        if left.rank != right.rank { return left.rank < right.rank }
        if left.count != right.count { return left.count < right.count }
        for index in 0..<left.count where left.name[index] != right.name[index] {
            return left.name[index] < right.name[index]
        }
        return false
    }
}
