//
//  Arity.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// How many arguments a verb takes, and the line to print when it was handed
/// another number.
///
/// One type because it was nowhere: some verbs counted their arguments, some
/// counted them and printed a sentence written on the spot, and some took
/// whatever was typed and ignored the rest. `disk.info hello` did the same thing
/// as `disk.info`, which reads to the person typing as an argument that means
/// something.
///
/// The usage line is part of the arity rather than of the module for the same
/// reason: a refusal that does not say the shape of the command is a refusal
/// that has to be looked up somewhere else.
public struct Arity {

    /// The fewest arguments the verb will act on.
    public let least: Int

    /// The most it will act on. Equal to `least` for every verb but one.
    public let most: Int

    /// What to print when the count is wrong: the command's shape, as typed.
    public let usage: StaticString


    public init(
        _ least: Int,
        _ most : Int,
        _ usage: StaticString
    ) {
        self.least = least
        self.most  = most
        self.usage = usage
    }

    /// A verb that takes exactly this many.
    public static func exactly(
        _ count: Int,
        _ usage: StaticString
    ) -> Arity {
        Arity(count, count, usage)
    }

    /// A verb that takes nothing at all.
    public static func none(_ usage: StaticString) -> Arity {
        Arity(0, 0, usage)
    }


    /// Whether `count` arguments is a number this verb acts on.
    ///
    /// A negative count cannot arrive from the parser, and is refused anyway:
    /// this is the check that stands between a number and a verb doing something
    /// with it, so it does not get to assume where the number came from.
    public func accepts(_ count: Int) -> Bool {
        count >= 0 && count >= least && count <= most
    }
}
