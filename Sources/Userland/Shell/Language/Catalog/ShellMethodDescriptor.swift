//
//  ShellMethodDescriptor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What one method takes, which is all the editor needs to offer it.
public enum ShellMethodArgument: UInt8, Equatable {
    case none
    case closure
    case text
}

/// What a method answers with, which is not always a type: some of them
/// answer with whatever they were given, and some with whatever a closure
/// handed back.
public enum ShellMethodResult: Equatable {
    /// The same thing that was asked: `filter` of a list of entries is a list
    /// of entries.
    case sameAsReceiver

    /// A list of whatever the closure answered, which is what `map` is.
    case listOfClosureAnswer

    /// Whatever the closure answered, already a list: `flatMap`.
    case closureAnswer

    /// A type that depends on nothing: `contains` is a Bool wherever it is.
    case fixed(ShellTypeSchema)
}

/// One method the runtime answers on a value, described rather than guessed.
///
/// Methods belong to a type: a list has `filter`, a text has `contains`, and
/// asking a catalog for one asks about the type it is on.
public struct ShellMethodDescriptor {
    public let name    : StaticString
    public let argument: ShellMethodArgument
    public let result  : ShellMethodResult
    public let summary : StaticString

    public init(
        _ name    : StaticString,
          argument: ShellMethodArgument,
          result  : ShellMethodResult,
          summary : StaticString
    ) {
        self.name = name
        self.argument = argument
        self.result = result
        self.summary = summary
    }

    /// What this answers with on a given receiver, as far as it can be known
    /// without reading the closure.
    public func resultType(
        on receiver: ShellTypeSchema,
        closure    : ShellTypeSchema = .none
    ) -> ShellTypeSchema {
        switch result {
            case .sameAsReceiver: return receiver
            case .fixed(let type): return type
            case .closureAnswer: return closure
            case .listOfClosureAnswer:
                // The evaluator keeps whatever a closure answers as an object
                // with a name, unless it was an entry to begin with.
                if closure.shape == .one, closure.element == .entry { return receiver }
                if closure.isEmptyType { return ShellTypeSchema(shape: .list, element: .named) }
                return ShellTypeSchema(shape: .list, element: .named)
        }
    }

    /// How the answer is written where the closure is not known yet.
    public func resultName(on receiver: ShellTypeSchema) -> StaticString {
        switch result {
            case .sameAsReceiver: return receiver.name
            case .fixed(let type): return type.name
            case .closureAnswer, .listOfClosureAnswer: return "[?]"
        }
    }
}
