//
//  TypedShellNode.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum TypedShellNode {
    case literal(Span)
    case identifier(Span)
    case call(TypedShellCallSyntax)
    case member(base: Int, name: Span)
    case method(base: Int, name: Span, argument: Int?)
    case closure(Int)
    case unaryNot(Int)
    case binary(TypedShellBinaryOperator, Int, Int)
}
