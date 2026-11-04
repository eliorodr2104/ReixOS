//
//  TypedShellCallSyntax.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellCallSyntax {
    public let namespace : Span
    public let name      : Span
    public var labels    = InlineArray<4, Span?>(repeating: nil)
    public var values    = InlineArray<4, Int>(repeating: -1)
    public var count     = 0
}
