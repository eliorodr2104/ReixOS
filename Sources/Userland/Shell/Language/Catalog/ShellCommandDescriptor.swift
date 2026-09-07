//
//  ShellCommandDescriptor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Everything the shell knows about one command before it runs.
///
/// The signature is what resolution needs; the rest is what a person needs,
/// and both are written by the provider that answers the command, so help
/// cannot describe something the parser does not have.
public struct ShellCommandDescriptor {

    /// The provider's own name for this command. Meaningless outside it: the
    /// catalog carries it back so dispatch does not have to match spellings.
    public let code       : UInt16

    /// How the provider's own handler spells this verb.
    public let verb       : StaticString
    public let signature  : TypedShellSignature

    /// The authority this command acts through. A shell that was handed no
    /// such capability cannot run it, so nothing offers it either.
    public let capability : BootCap?

    /// Changes something a later command cannot put back.
    public let sensitive  : Bool

    /// What the answer is, when the value type alone does not say it. For a
    /// sequence this describes one element.
    public let schema     : ShellTypeSchema
    public let summary    : StaticString

    public init(
        code      : UInt16,
        verb      : StaticString,
        signature : TypedShellSignature,
        capability: BootCap? = nil,
        sensitive : Bool = false,
        schema    : ShellTypeSchema = .none,
        summary   : StaticString
    ) {
        self.code = code
        self.verb = verb
        self.signature = signature
        self.capability = capability
        self.sensitive = sensitive
        self.schema = schema
        self.summary = summary
    }
}
