//
//  ShellModule.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// One receiver of the shell's language, and everything it can be asked.
///
/// The shape a program will conform to when the shell starts answering
/// programs instead of only running them. Today every module is compiled in;
/// the contract is written now so that what changes then is where the modules
/// come from and not what a module is.
///
/// Static, deliberately: a module holds no state of its own. What state there
/// is belongs to the session, which is handed in and handed back changed. A
/// module that wanted its own would be a module the shell could not restart.
public protocol ShellModule {

    /// The name that selects this module: `fs`, `process`, `disk`.
    ///
    /// A receiver is not decoration. It names the authority a command acts
    /// through, so `process.spawn` reads as what it is, and a receiver the
    /// shell holds no capability for simply does not answer.
    static var receiver: StaticString { get }

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

    /// One line per verb, printed by `help`.
    static func describe()
}


public extension ShellModule {
    static func handleResult(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellCommandResult {
        ShellCommandResult(outcome: handle(command, in: &session))
    }
}
