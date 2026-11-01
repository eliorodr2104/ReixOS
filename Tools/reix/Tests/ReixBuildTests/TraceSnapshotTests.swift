import Testing
@testable import ReixBuild

@Suite struct TraceSnapshotTests {
    private let begin = "[TRACE] begin v=2 freq=62500000 lost=0 stack=0 exstack=0"
    private let event = "[TRACE] t=1 ev=sample pid=1 info=0 a=0x10 b=0x20"

    @Test func refusesOverwrittenSnapshot() {
        #expect(throws: (any Error).self) {
            try decode([
                begin, event, "[TRACE-DROP] omitted=1", "[TRACE] end count=1"
            ])
        }
    }

    @Test func refusesCountMismatch() {
        #expect(throws: (any Error).self) {
            try decode([begin, event, "[TRACE] end count=2"])
        }
    }

    @Test func refusesNestedSnapshot() {
        #expect(throws: (any Error).self) {
            try decode([begin, event, begin, event, "[TRACE] end count=1"])
        }
    }

    @Test func refusesMalformedNestedHeader() {
        #expect(throws: (any Error).self) {
            try decode([begin, "[TRACE] begin v=2 freq=1 lost=0 stack=0", event, "[TRACE] end count=1"])
        }
    }

    @Test func refusesMalformedPayloadEvenWhenCountMatches() {
        #expect(throws: (any Error).self) {
            try decode([begin, "[TRACE] t=broken", event, "[TRACE] end count=1"])
        }
    }

    @Test func keepsOnlyTheLastCompleteSnapshot() throws {
        let extraction = try decode([
            begin, event, "[TRACE] end count=1", begin, "timer output",
            "[TRACE] t=2 ev=sample pid=2 info=0 a=0x30 b=0x40", "[TRACE] end count=1"
        ])
        #expect(extraction.block.events.count == 1)
        #expect(extraction.block.events.first?.pid == 2)
    }
    @Test func cumulativeMaximaSurviveOlderRecordsLaterInTheDump() throws {
        let extraction = try decode([begin,
            "[TRACE] t=20 ev=irqOff pid=0 info=33 a=200 b=0",
            "[TRACE] t=10 ev=irqOff pid=0 info=33 a=100 b=0",
            "[TRACE] t=30 ev=irqOff pid=0 info=64 a=300 b=0",
            "[TRACE] end count=3"])
        let maxima = TraceDecoder.irqOffMaxima(extraction.block.events)
        #expect(maxima[33] == 200)
        #expect(maxima[64] == 300)
    }

    private func decode(_ lines: [String]) throws -> TraceDecoder.Extraction {
        try TraceDecoder.extractLastBlock(from: lines)
    }
}
