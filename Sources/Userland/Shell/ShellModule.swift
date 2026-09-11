//
//  ShellModule.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// The language-level reason a module is being asked for live candidates.
///
/// `code` is the module's own command identity and `parameter` is the same
/// declaration the analyzer used for highlighting. A module implements one
/// policy for a kind of parameter; it does not repeat a list of command names.
public struct ShellModuleCompletionRequest {
    public let code     : UInt16
    public let parameter: TypedShellParameter
    public let context  : ShellCompletionContext

    public init(
        code     : UInt16,
        parameter: TypedShellParameter,
        context  : ShellCompletionContext
    ) {
        self.code = code
        self.parameter = parameter
        self.context = context
    }
}

/// One receiver of the shell's language, and everything it can be asked.
///
/// The shape a program will conform to when the shell starts answering
/// programs instead of only running them. Today every module is compiled in;
/// the contract is written now so that what changes then is where the modules
/// come from and not what a module is.
///
/// A module documents itself: `ShellCommandProvider` has no default, so a
/// receiver that answers a verb it never declared cannot be written. What the
/// modules declare is what the catalog merges, and the catalog is what the
/// parser, help and the editor read.
///
/// Static, deliberately: a module holds no state of its own. What state there
/// is belongs to the session, which is handed in and handed back changed. A
/// module that wanted its own would be a module the shell could not restart.
public protocol ShellModule: ShellCommandProvider {

    /// Carries out one command.
    ///
    /// `notHandled` when the verb is none of this module's, which is how a
    /// command with no receiver written finds the module that owns its verb.
    static func handle(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellOutcome

    static func handleResult(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellCommandResult

    /// Answers a declared command with a value instead of with records.
    ///
    /// `nil` means the ordinary path: the command is spelled out and handed to
    /// `handleResult` like any other.
    static func value(
        for code  : UInt16,
        in session: inout ShellSession
    ) -> TypedShellInvocationResult?

    /// The module's last word on a command before its handler sees it.
    ///
    /// `cursor` is where the spelled-out line ends, so an argument appended
    /// here names nothing rather than borrowing somebody else's bytes.
    static func fill(
        _ command: inout Command,
          for code: UInt16,
          at cursor: Int
    ) -> Bool

    /// Adds live candidates for one declared parameter.
    ///
    /// Completion is observational: the session is a disposable snapshot of
    /// the shell's place, and the pipeline never writes changes to it back.
    /// Implementations must remain bounded and must use only authority carried
    /// by that session. Modules with no live vocabulary inherit the no-op.
    static func complete(
        _ request: ShellModuleCompletionRequest,
          in session: inout ShellSession,
          into offered: inout ShellCompletionSet
    )
}


public extension ShellModule {
    static func handleResult(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellCommandResult {
        ShellCommandResult(outcome: handle(command, in: &session))
    }

    static func value(
        for code  : UInt16,
        in session: inout ShellSession
    ) -> TypedShellInvocationResult? { nil }

    static func fill(
        _ command: inout Command,
          for code: UInt16,
          at cursor: Int
    ) -> Bool { true }

    static func complete(
        _ request: ShellModuleCompletionRequest,
          in session: inout ShellSession,
          into offered: inout ShellCompletionSet
    ) {}
}
