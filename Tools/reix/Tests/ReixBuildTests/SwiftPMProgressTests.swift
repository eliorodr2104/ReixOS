//
//  SwiftPMProgressTests.swift
//  ReixOS
//

import Testing
import Foundation
@testable import ReixBuild

@Suite struct SwiftPMProgressTests {

    @Test func readsTheCountAndTheWorkFromARealLine() {
        let update = SwiftPMProgress.parse("[61/75] Compiling BlockServer BlockServer.swift")
        #expect(update == .init(done: 61, total: 75, detail: "Compiling BlockServer BlockServer.swift"))
    }

    @Test func readsTheOtherShapesSwiftPMEmits() {
        #expect(SwiftPMProgress.parse("[66/77] Archiving libKernel.a")?.done == 66)
        #expect(SwiftPMProgress.parse("[61/77] Wrapping AST for Kernel for debugging")?.total == 77)
        #expect(SwiftPMProgress.parse("[62/77] Write Objects.LinkFileList")?.detail == "Write Objects.LinkFileList")
    }

    @Test func ignoresEverythingThatIsNotAProgressLine() {
        #expect(SwiftPMProgress.parse("Build complete! (18.01s)") == nil)
        #expect(SwiftPMProgress.parse("") == nil)
        #expect(SwiftPMProgress.parse("[abc/77] Compiling Kernel") == nil)
        #expect(SwiftPMProgress.parse("[61/] Compiling Kernel") == nil)
        #expect(SwiftPMProgress.parse("warning: 'foo' is deprecated") == nil)
    }

    @Test func aTotalThatGrowsIsFollowed() {
        // SwiftPM revises the denominator upward as it discovers work.
        var tracker = ProgressTracker()
        let clock   = ContinuousClock()
        _ = tracker.ingest("[61/75] Compiling BlockServer BlockServer.swift", at: clock.now)
        let state = tracker.ingest("[61/77] Wrapping AST for Kernel for debugging", at: clock.now)
        #expect(state == .bar(done: 61, total: 77, detail: "Wrapping AST for Kernel for debugging"))
    }

    @Test func anUnrecognisedFormatDegradesToASpinnerRatherThanAStalledBar() {
        var tracker = ProgressTracker(stallAfter: .seconds(5))
        let start   = ContinuousClock().now

        #expect(tracker.ingest("[61/75] Compiling BlockServer", at: start)
                == .bar(done: 61, total: 75, detail: "Compiling BlockServer"))

        // Four seconds of output it does not understand: still believes the bar.
        #expect(tracker.ingest("<< some future format >>", at: start.advanced(by: .seconds(4)))
                == .bar(done: 61, total: 75, detail: "Compiling BlockServer"))

        // Past the stall window it stops claiming a number it no longer has.
        #expect(tracker.ingest("<< some future format >>", at: start.advanced(by: .seconds(6)))
                == .spinner(lastLine: "<< some future format >>"))
    }

    @Test func aRecognisedLineRecoversTheBar() {
        var tracker = ProgressTracker(stallAfter: .seconds(5))
        let start   = ContinuousClock().now
        _ = tracker.ingest("<< junk >>", at: start)
        _ = tracker.ingest("<< junk >>", at: start.advanced(by: .seconds(6)))

        #expect(tracker.ingest("[70/79] Archiving libShell.a", at: start.advanced(by: .seconds(7)))
                == .bar(done: 70, total: 79, detail: "Archiving libShell.a"))
    }
}
