import Testing
import KernelHostShims
@testable import Kernel

private var traceWindowHook: (() -> Void)?
private var traceWire: [UInt8] = []

/// These tests own the ring, serial hooks and clock; run with --no-parallel.
extension KernelPolicyTestRoot {
@Suite("Chunked trace dump", .serialized)
struct TraceDumpTests {
    @Test("a full transcript drains without overflowing the transmit queue")
    func fullTranscript() {
        withDumpState {
            for index in 0..<TraceRing.capacity {
                TraceRing.append(TraceEvent(timestamp: UInt64(index), code: TraceCode.sample,
                    info: .max, pid: .max, a: .max, b: .max))
            }
            let dropped = LogSink.droppedTransmissionRecords
            #expect(TraceDump.toConsole(processManager: nil))
            let text = String(decoding: traceWire, as: UTF8.self)
            #expect(!text.contains("[TRACE-DROP]"))
            #expect(text.contains("[TRACE] end count="))
            #expect(text.split(separator: "\n").filter { $0.contains("ev=sample ") }.count == Int(TraceRing.capacity))
            #expect(LogSink.droppedTransmissionRecords == dropped)
        }
    }

    @Test("a timer emit in the first window stays outside the dump generation")
    func windowAppend() {
        withDumpState {
            TraceRing.append(TraceEvent(timestamp: 1, code: TraceCode.sample))
            TraceRing.append(TraceEvent(timestamp: 2, code: TraceCode.sample))
            var windows = 0
            traceWindowHook = {
                windows += 1
                if windows == 1 { TraceRing.append(TraceEvent(timestamp: 9999, code: TraceCode.sample)) }
            }
            #expect(TraceDump.toConsole(processManager: nil))
            let text = String(decoding: traceWire, as: UTF8.self)
            #expect(windows > 1)
            #expect(text.contains("t=1 ev=sample") && text.contains("t=2 ev=sample"))
            #expect(!text.contains("t=9999 ev=sample"))
        }
    }

    @Test("a full snapshot protects unread records from timer eviction")
    func windowProtection() {
        withDumpState {
            for index in 0..<TraceRing.capacity {
                TraceRing.append(TraceEvent(timestamp: UInt64(index), code: TraceCode.sample))
            }
            var windows = 0
            traceWindowHook = {
                windows += 1
                if windows == 1 { TraceRing.append(TraceEvent(timestamp: 9999, code: TraceCode.sample)) }
            }
            let rejected = TraceRing.rejected
            #expect(TraceDump.toConsole(processManager: nil))
            let text = String(decoding: traceWire, as: UTF8.self)
            #expect(!text.contains("[TRACE-DROP]"))
            #expect(TraceRing.rejected == rejected + 1)
            #expect(text.split(separator: "\n").filter { $0.contains("ev=sample ") }.count == Int(TraceRing.capacity))
            #expect(!text.contains("t=9999 ev=sample"))
        }
    }

    @Test("an active snapshot refuses a second dump without opening a transcript")
    func activeSnapshotRefusal() throws {
        try withDumpState {
            TraceRing.append(TraceEvent(timestamp: 1))
            let snapshot = try #require(TraceRing.protectSnapshot())
            defer { snapshot.release() }
            #expect(!TraceDump.toConsole(processManager: nil))
            #expect(traceWire.isEmpty)
        }
    }

    @Test("a reset during a window discloses failure and releases protection")
    func resetDuringWindow() {
        withDumpState {
            TraceRing.append(TraceEvent(timestamp: 1, code: TraceCode.sample))
            var windows = 0
            traceWindowHook = {
                windows += 1
                if windows == 1 { TraceRing.reset() }
            }
            #expect(!TraceDump.toConsole(processManager: nil))
            #expect(String(decoding: traceWire, as: UTF8.self).contains("[TRACE-DROP] omitted=1"))
            traceWindowHook = nil
            #expect(TraceDump.toConsole(processManager: nil))
        }
    }

    @Test("header exhaustion returns failure and releases the unread suffix")
    func headerExhaustion() {
        withDumpState {
            TraceRing.append(TraceEvent(timestamp: 1))
            LogSink.beginTransmission()
            for _ in 0..<SerialTransmitQueue.capacity { LogSink.transmit(65) }
            #expect(LogSink.endTransmission())
            host_set_serial_write_hook { _ in 0 }
            #expect(!TraceDump.toConsole(processManager: nil))
            let next = TraceRing.protectSnapshot()
            #expect(next != nil)
            next?.release()
            _ = LogSink.drain(budget: .max) { _ in true }
        }
    }

    @Test("cumulative IRQ maxima survive a trace mask that excludes latency events")
    func cumulativePathMaxima() {
        withDumpState {
            IrqOffStretch.fold(12_345, path: 33)
            #expect(TraceRing.count == 0)
            #expect(TraceDump.toConsole(processManager: nil))
            #expect(String(decoding: traceWire, as: UTF8.self).contains("info=33 a=12345 b=0"))
        }
    }

    private func withDumpState(_ body: () throws -> Void) rethrows {
        let savedMode = LogSink.mode
        let savedMask = Trace.runtimeMask
        let savedBase = Kernel.platformInfo.uart.baseAddr
        LogSink.mode = .deferred
        _ = LogSink.drain(budget: .max) { _ in true }
        Trace.runtimeMask = 0
        Kernel.platformInfo.uart.baseAddr = 1
        TraceRing.reset()
        IrqOffStretch.reset()
        PreemptionSpans.reset()
        host_set_virtual_counter(0)
        host_set_counter_frequency(0)
        traceWire = []
        host_set_interrupt_window_hook { traceWindowHook?() }
        host_set_serial_write_hook { byte in traceWire.append(byte); return 1 }
        defer {
            host_set_interrupt_window_hook(nil)
            host_set_serial_write_hook(nil)
            traceWindowHook = nil
            traceWire = []
            TraceRing.reset()
            IrqOffStretch.reset()
            PreemptionSpans.reset()
            Trace.runtimeMask = savedMask
            Kernel.platformInfo.uart.baseAddr = savedBase
            LogSink.mode = savedMode
        }
        try body()
    }
}
}
