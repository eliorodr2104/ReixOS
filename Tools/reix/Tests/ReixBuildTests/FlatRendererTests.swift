//
//  FlatRendererTests.swift
//  ReixOS
//

import Testing
import Foundation
@testable import ReixBuild

/// The renderer that CI, Xcode and every pipe get. It is a pure function of one
/// event, which is what makes it testable and what keeps it honest: it cannot
/// decide to withhold something because of what it saw earlier.
@Suite struct FlatRendererTests {

    @Test func aFinishedPhaseIsOneAlignedLine() {
        let line = FlatRenderer.line(for: .ended(.userland, summary: "13 programs", elapsed: .seconds(2)))
        #expect(line == "  userland    13 programs")
    }

    @Test func aBegunPhaseSaysWhatItIsAboutToDo() {
        let line = FlatRenderer.line(for: .began(.compile, why: "79 modules"))
        #expect(line == "  compile     79 modules ...")
    }

    @Test func progressIsSilentBecauseThereIsNowhereToRedraw() {
        #expect(FlatRenderer.line(for: .progress(.compile, done: 9, total: 79, now: "Shell")) == nil)
    }

    /// The dashboard's live tail reads these. Printing them here would put a
    /// tool's whole transcript into the stdout the shell scripts parse.
    @Test func aToolsOwnLinesAreSilentToo() {
        #expect(FlatRenderer.line(for: .output(.compile, line: "[9/79] Compiling Shell")) == nil)
    }

    @Test func aSkippedPhaseSaysWhyItWasSkipped() {
        let line = FlatRenderer.line(for: .skipped(.compile, because: "already up to date"))
        #expect(line == "  compile     skipped, already up to date")
    }

    @Test func aFailureIsNotReflowed() {
        let wall = "ld.lld: error: undefined symbol: _start\n>>> referenced by boot.S:12"
        let line = FlatRenderer.line(for: .failed(.image, output: wall))
        #expect(line == "  image       FAILED\n" + wall)
    }
}
