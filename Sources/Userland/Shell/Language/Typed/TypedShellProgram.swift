//
//  TypedShellProgram.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellProgram {
    var nodes      = InlineArray<64, TypedShellNode?>(repeating: nil)
    var nodeCount  = 0
    var statements = InlineArray<16, TypedShellStatement?>(repeating: nil)
    public private(set) var count = 0

    public init() {}

    public func statement(at index: Int) -> TypedShellStatement? {
        guard index >= 0, index < count else { return nil }
        return statements[index]
    }

    mutating func append(_ node: TypedShellNode) -> Int? {
        guard nodeCount < nodes.count else { return nil }
        nodes[nodeCount] = node
        defer { nodeCount += 1 }
        return nodeCount
    }

    mutating func append(_ statement: TypedShellStatement) -> Bool {
        guard count < statements.count else { return false }
        statements[count] = statement
        count += 1
        return true
    }
}
