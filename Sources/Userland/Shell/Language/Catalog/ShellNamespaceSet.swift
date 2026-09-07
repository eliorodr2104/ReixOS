//
//  ShellNamespaceSet.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// The receivers the parser is allowed to read as receivers.
///
/// Writing `fileSystem.changeDir vault` without parentheses only reads as a
/// call because `fileSystem` is a receiver somebody documented. A parser with
/// an empty set treats every `a.b` as reaching into a value, which is what it
/// is when nothing claims the name.
public struct ShellNamespaceSet {
    private var names = InlineArray<8, StaticString?>(repeating: nil)
    public private(set) var count = 0

    public init() {}

    public mutating func insert(_ name: StaticString) -> Bool {
        guard count < names.count else { return false }
        names[count] = name
        count += 1
        return true
    }

    public func name(at index: Int) -> StaticString? {
        guard index >= 0, index < count else { return nil }
        return names[index]
    }

    /// Whether `span` of `source` spells one of these receivers.
    public func contains(
        _ source: UnsafePointer<UInt8>,
          span  : Span
    ) -> Bool {
        for index in 0..<count {
            guard let name = names[index], name.utf8CodeUnitCount == span.count else { continue }
            var same = true
            for offset in 0..<span.count where source[span.start + offset] != name.utf8Start[offset] {
                same = false
                break
            }
            if same { return true }
        }
        return false
    }
}
