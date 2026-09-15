//
//  PhaseRunnerTests.swift
//  ReixOS
//

import Testing
import Foundation
@testable import ReixBuild

@Suite struct PhaseRunnerTests {

    /// Collects what a run emitted, in order.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [BuildEvent] = []

        var sink: EventSink {
            EventSink { event in
                self.lock.lock(); self.events.append(event); self.lock.unlock()
            }
        }
        var recorded: [BuildEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    @Test func runsStepsInOrderAndBracketsEachOne() async {
        let recorder = Recorder()
        let ok = await PhaseRunner.run([
            .init(phase: .prune,   why: "2 trees") { _ in .done("2 copies") },
            .init(phase: .compile, why: "79 modules") { _ in .done("79 modules") },
        ], into: recorder.sink)

        #expect(ok)
        let phases = recorder.recorded.map(\.phase)
        #expect(phases == [.prune, .prune, .compile, .compile])
        if case .began(.prune, let why) = recorder.recorded[0] { #expect(why == "2 trees") }
        else { Issue.record("first event is not .began(.prune)") }
        if case .ended(.compile, let summary, _) = recorder.recorded[3] { #expect(summary == "79 modules") }
        else { Issue.record("last event is not .ended(.compile)") }
    }

    @Test func aSkippedStepSaysWhyAndDoesNotStopTheRun() async {
        let recorder = Recorder()
        let ok = await PhaseRunner.run([
            .init(phase: .compile, why: "79 modules") { _ in .skipped("already up to date") },
            .init(phase: .image,   why: "link") { _ in .done("kernel 412 KiB") },
        ], into: recorder.sink)

        #expect(ok)
        if case .skipped(.compile, let because) = recorder.recorded[1] {
            #expect(because == "already up to date")
        } else { Issue.record("expected .skipped(.compile)") }
        #expect(recorder.recorded.map(\.phase).contains(.image))
    }

    @Test func aFailureStopsTheRunAndCarriesTheToolOutputWhole() async {
        let recorder = Recorder()
        let wall = "ld.lld: error: undefined symbol: _start\n>>> referenced by boot.S:12\n"
        let ok = await PhaseRunner.run([
            .init(phase: .image, why: "link") { _ in throw ReixError.tool(wall) },
            .init(phase: .disk,  why: "provision") { _ in .done("never reached") },
        ], into: recorder.sink)

        #expect(!ok)
        if case .failed(.image, let output) = recorder.recorded[1] { #expect(output == wall) }
        else { Issue.record("expected .failed(.image)") }
        #expect(!recorder.recorded.map(\.phase).contains(.disk))
    }

    @Test func aStepCanEmitProgressOfItsOwn() async {
        let recorder = Recorder()
        _ = await PhaseRunner.run([
            .init(phase: .userland, why: "13 programs") { sink in
                sink(.progress(.userland, done: 9, total: 13, now: "Shell"))
                return .done("13 programs")
            },
        ], into: recorder.sink)

        if case .progress(.userland, let done, let total, let now) = recorder.recorded[1] {
            #expect(done == 9); #expect(total == 13); #expect(now == "Shell")
        } else { Issue.record("expected .progress(.userland)") }
    }
}
