//
//  ShellOutcome.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// What running one command came to.
///
/// Three answers where there was a `Bool`, because "none of my verbs" and
/// "carried out, and the shell should stop" were the same true and false as
/// everything else, and a shell that wanted to stop had to reach into its own
/// state from inside a module to do it.
///
/// Whether a verb *succeeded* is deliberately not here: a refusal from the disk
/// or from the file system is a value the module already holds and prints
/// itself, and folding it in would make every caller of a module decide what to
/// say about somebody else's error.
///
/// In the language rather than beside the modules for the reason the verb
/// signatures are: the modules are built against the syscall stubs and cannot be
/// reached from a host suite, so a rule kept there is a rule nothing holds to.
public enum ShellOutcome {

    /// None of this module's verbs. The next module is asked.
    case notHandled

    /// Carried out, whatever came of the carrying out.
    case handled

    /// Carried out, and the shell should stop reading lines.
    case exitRequested


    /// Whether a shell that saw this outcome stops reading lines.
    ///
    /// One answer, so the loop is not a chain of comparisons written out at the
    /// place that happens to end it. The shell turns its flag off when this is
    /// true and never turns it back on: stopping is a decision, and reading it
    /// as `running = !stops` would let the next command undo it.
    public var stopsTheShell: Bool {
        switch self {
            case .notHandled, .handled: false
            case .exitRequested       : true
        }
    }
}
