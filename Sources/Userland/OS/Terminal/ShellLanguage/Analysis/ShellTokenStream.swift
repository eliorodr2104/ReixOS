//
//  ShellTokenStream.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// One reading of one revision: bounded, owning nothing, allocating nothing.
public struct ShellTokenStream {
    public static let capacity = 256

    private var tokens = InlineArray<256, ShellToken?>(repeating: nil)

    public private(set) var count = 0

    /// More tokens than there was room for. What is here is still the front of
    /// the line, in order; nothing was dropped from the middle.
    public private(set) var truncated = false

    /// How finished the revision is, by the same reading the editor uses to
    /// decide whether Enter runs a line or opens one.
    public internal(set) var completeness: ShellCompleteness = .complete

    public init() {}

    internal mutating func markTruncated() {
        truncated = true
    }

    @discardableResult
    internal mutating func append(_ token: ShellToken) -> Bool {
        guard count < tokens.count else {
            truncated = true
            return false
        }
        tokens[count] = token
        count += 1
        return true
    }

    public func token(at index: Int) -> ShellToken? {
        guard index >= 0, index < count else { return nil }
        return tokens[index]
    }

    /// The token the cursor is inside or touching the end of.
    ///
    /// Touching matters more than being inside: a cursor just past the last
    /// byte of a name is what somebody typing that name looks like.
    public func index(touching offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        for index in 0..<count {
            guard let token = tokens[index], token.kind != .newline else { continue }
            if offset >= Int(token.start), offset <= token.end { return index }
        }
        return nil
    }

    /// The last token that ends at or before `offset`, which is what precedes
    /// a cursor sitting in open space.
    public func index(before offset: Int) -> Int? {
        var found: Int?
        for index in 0..<count {
            guard let token = tokens[index] else { continue }
            if token.end <= offset { found = index } else { break }
        }
        return found
    }
}
