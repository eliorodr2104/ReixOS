//
//  OutcomeTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ShellLanguage

/// What the shell does after one command.
///
/// The loop that reads lines is in the shell itself and cannot be reached from a
/// host - it is built against the syscall stubs - so what is held here is the
/// rule it reads: which outcome stops a shell, and that the other two do not.
@Suite("Command outcome")
struct OutcomeTests {

    @Test("only a request to exit stops the shell")
    func onlyExitStops() {
        #expect(ShellOutcome.exitRequested.stopsTheShell)

        // Neither of these, and the second is the one that matters: a verb that
        // failed has been carried out. A disk that would not answer is not a
        // reason to close the terminal.
        #expect(!ShellOutcome.handled.stopsTheShell)
        #expect(!ShellOutcome.notHandled.stopsTheShell)
    }


    @Test("the rule is a switch over every case, so a new outcome has to answer it")
    func everyCaseAnswers() {
        // Written out rather than looped over a collection: the point is that
        // this list is exhaustive today and that adding a case makes the
        // property below fail to compile until somebody says what it does.
        let outcomes: [ShellOutcome] = [.notHandled, .handled, .exitRequested]

        #expect(outcomes.filter(\.stopsTheShell).count == 1)
    }
}
