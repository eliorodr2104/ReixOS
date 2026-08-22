//
//  IRQSerialPathTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel

/// This suite owns `LogSink` (mode, transmit queue, drop counter) and
/// `TraceRing` for its duration, and `.serialized` only orders its own tests.
/// The run needs `swift test --no-parallel` (see the `test` target in the Makefile).
@Suite("IRQ serial production path", .serialized)
struct IRQSerialPathTests {
    @Test("timer budget bounds probes and a large trace dump stays framed")
    func boundedDrainAndTraceDisclosure() {
        LogSink.mode = .deferred
        defer { LogSink.mode = .synchronous }

        LogSink.beginTransmission()
        for byte in UInt8(0)..<64 { LogSink.transmit(byte) }
        #expect(LogSink.endTransmission())

        var probes = 0
        let blocked = LogSink.drain(budget: LogSink.tickBudget) { _ in
            probes += 1
            return false
        }
        #expect(blocked == 0)
        #expect(probes == 1)

        probes = 0
        let first = LogSink.drain(budget: LogSink.tickBudget) { _ in
            probes += 1
            return true
        }
        #expect(first == LogSink.tickBudget)
        #expect(probes == LogSink.tickBudget)
        #expect(LogSink.drain(budget: .max) { _ in true } == 32)

        TraceRing.reset()
        for index in 0..<TraceRing.capacity {
            TraceRing.append(TraceEvent(
                timestamp: UInt64.max - UInt64(index),
                code: TraceCode.sample,
                info: UInt16.max,
                pid: UInt32.max,
                a: UInt64.max,
                b: UInt64.max
            ))
        }

        let dropsBefore = LogSink.droppedTransmissionRecords
        let complete = TraceDump.toConsole(processManager: nil)

        var output: [UInt8] = []
        _ = LogSink.drain(budget: .max) { output.append($0); return true }
        let text = String(decoding: output, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        let events = lines.filter { $0.hasPrefix("[TRACE] t=") }

        #expect(!complete)
        #expect(LogSink.droppedTransmissionRecords > dropsBefore)
        #expect(lines.contains { $0.hasPrefix("[TRACE-DROP] omitted=") })
        #expect(lines.contains("[TRACE] end count=\(events.count)"))
    }
}
