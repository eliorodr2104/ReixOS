//
//  ShellAnalysisSnapshot.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// One reading of one revision, and the only thing the editor's colours,
/// completions and diagnostics are allowed to be built from.
///
/// It carries the revision it was taken of. Anything holding a snapshot has to
/// ask whether it still fences the revision in hand before drawing from it: a
/// keystroke that arrived while this was being computed makes every offset in
/// here a statement about bytes that have moved.
public struct ShellAnalysisSnapshot {
    public static let spanCapacity       = 64
    public static let diagnosticCapacity = 8

    private var spans       = InlineArray<64, ShellSemanticSpan?>(repeating: nil)
    private var findings    = InlineArray<8, ShellDiagnostic?>(repeating: nil)
    private var bound       = InlineArray<8, ShellSemanticSpan?>(repeating: nil)

    public let revision: UInt32
    public internal(set) var completeness: ShellCompleteness = .complete

    /// The revision was longer than the analysis reads, or held more than it
    /// has room for. What is here is the front of it, in order.
    public internal(set) var truncated = false

    public internal(set) var context = ShellCompletionContext()

    public private(set) var spanCount       = 0
    public private(set) var diagnosticCount = 0

    /// The names `let` gave a value in this revision, in the order they were
    /// written. What completion offers where a value goes.
    public private(set) var bindingCount    = 0

    public init(revision: UInt32) {
        self.revision = revision
    }

    /// Whether this still describes the bytes somebody has in hand.
    public func fences(_ revision: UInt32) -> Bool { self.revision == revision }

    public func span(at index: Int) -> ShellSemanticSpan? {
        guard index >= 0, index < spanCount else { return nil }
        return spans[index]
    }

    public func binding(at index: Int) -> ShellSemanticSpan? {
        guard index >= 0, index < bindingCount else { return nil }
        return bound[index]
    }

    public func diagnostic(at index: Int) -> ShellDiagnostic? {
        guard index >= 0, index < diagnosticCount else { return nil }
        return findings[index]
    }

    /// The role covering a byte, which is what a renderer walking a line asks.
    public func role(at offset: Int) -> ShellSemanticRole {
        for index in 0..<spanCount {
            guard let span = spans[index] else { continue }
            if offset >= Int(span.start), offset < span.end { return span.role }
        }
        return .plain
    }

    internal mutating func append(_ span: ShellSemanticSpan) {
        guard span.count > 0 else { return }
        // Runs of one role are one span: a renderer paints ranges, and two
        // spans that touch would only cost it a redundant escape.
        if spanCount > 0, let last = spans[spanCount - 1],
           last.role == span.role, last.end == Int(span.start) {
            spans[spanCount - 1] = ShellSemanticSpan(
                role : last.role,
                start: last.start,
                count: last.count + span.count
            )
            return
        }
        guard spanCount < spans.count else {
            truncated = true
            return
        }
        spans[spanCount] = span
        spanCount += 1
    }

    internal mutating func remember(_ binding: ShellSemanticSpan) {
        guard bindingCount < bound.count else { return }
        bound[bindingCount] = binding
        bindingCount += 1
    }

    internal mutating func append(_ diagnostic: ShellDiagnostic) {
        guard diagnosticCount < findings.count else {
            truncated = true
            return
        }
        findings[diagnosticCount] = diagnostic
        diagnosticCount += 1
    }
}
