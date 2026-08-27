//
//  ShellSequence.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

/// A per-turn bounded eager materialization with an explicit budget.
///
/// A service may fetch records from its backend in batches, but its adapter
/// copies the complete accepted result into this value before `filter`, `map`,
/// `compactMap`, `flatMap` or `sorted` run. The sixty-fifth record is a typed
/// failure: this is deliberately bounded, not lazy or silently truncated, and
/// no closure is serializable.
public struct ShellSequence: Equatable {
    public static let materializationLimit = 64
    private var storage                    = InlineArray<64, ShellObject?>(repeating: nil)
    public private(set) var count = 0
    public private(set) var batches = 0

    public init() {}

    public mutating func beginBatch() { batches += 1 }

    public mutating func append(_ value: ShellObject) -> Result<Void, ShellSequenceFailure> {
        guard count < storage.count else {
            return .failure(.materializationLimit(Self.materializationLimit))
        }
        storage[count] = value
        count += 1
        return .success(())
    }

    public func value(at index: Int) -> ShellObject? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    mutating func replace(
          at index  : Int,
          with value: ShellObject
    ) {
        guard index >= 0, index < count else { return }
        storage[index] = value
    }

    public static func == (lhs: ShellSequence, rhs: ShellSequence) -> Bool {
        guard lhs.count == rhs.count, lhs.batches == rhs.batches else { return false }
        for index in 0..<lhs.count where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }
}
