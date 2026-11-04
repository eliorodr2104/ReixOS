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
    /// `{ $0.isFolder }` or `{ entry in entry.isFolder }`: the parameter is
    /// the name the body calls each element by, when it was given one.
    case closure(parameter: Span?, body: Int)
    case unaryNot(Int)
    case binary(TypedShellBinaryOperator, Int, Int)
}
