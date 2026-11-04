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
    public static let capacity = 16

    private var entries = InlineArray<16, ShellCompletion?>(repeating: nil)

    public private(set) var count   = 0

    /// How many candidates matched in all, including the ones that did not fit.
    public private(set) var matched = 0

    /// A bounded live provider may know that more source rows exist without
    /// scanning them. This keeps the popup honest without pretending to know
    /// how many of those rows would match.
    private var incomplete = false

    /// Nil is the unrestricted set used by generic panel/test construction.
    /// Completion queries carry their semantic site, including through module
    /// hooks, so incompatible candidates never enter the ordered storage.
    private let subject: ShellCompletionSubject?

    public init(subject: ShellCompletionSubject? = nil) {
        self.subject = subject
    }

    public var truncated: Bool { matched > count || incomplete }
    public var omitted: Int { max(matched - count, incomplete ? 1 : 0) }

    public mutating func markIncomplete() { incomplete = true }

    public func candidate(at index: Int) -> ShellCompletion? {
        guard index >= 0, index < count else { return nil }
        return entries[index]
    }

    /// Places a candidate in rank order, dropping the worst when full.
    ///
    /// Public because the static side is not the only side: a provider that
    /// answers with paths adds to the same bounded, ordered list.
    ///
    /// Band first, then shorter, then alphabetical. Nothing here consults
    /// time, memory addresses or insertion order, so the same line always
    /// offers the same list in the same order.
    public mutating func insert(_ candidate: ShellCompletion) {
        guard subject?.accepts(candidate.kind) ?? true else { return }
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
