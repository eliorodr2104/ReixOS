//
//  IrqOffStretchTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelHostShims
import KernelTestSupport
import ReixABI

/// `IrqOffStretch`, the trace ring and the shim's counter are all global, so
/// every test resets the three and leaves the counter at zero for the next suite.
extension KernelPolicyTestRoot {
@Suite("IRQ-off stretches", .serialized)
struct IrqOffStretchTests {

    @Test("an exception is filed under its syscall, an interrupt or the rest")
    func pathClassification() {
        var frame = Arch.TrapFrame()

        frame.esr = 0x15 << 26
        frame.x8  = 49
        #expect(IrqOffStretch.path(of: .synchronous, frame: &frame) == 49)

        frame.x8 = 0
        #expect(IrqOffStretch.path(of: .synchronous, frame: &frame) == 0)

        frame.x8 = UInt64(IrqOffPath.syscallLimit) - 1
        #expect(IrqOffStretch.path(of: .synchronous, frame: &frame) == 63)

        // A number past the table cannot index it and is filed with the rest.
        frame.x8 = UInt64(IrqOffPath.syscallLimit)
        #expect(IrqOffStretch.path(of: .synchronous, frame: &frame) == UInt16(IrqOffPath.otherException))

        frame.x8 = .max
        #expect(IrqOffStretch.path(of: .synchronous, frame: &frame) == UInt16(IrqOffPath.otherException))

        // A data abort with a syscall-looking x8 is still not a syscall.
        frame.esr = 0x24 << 26
        frame.x8  = 12
        #expect(IrqOffStretch.path(of: .synchronous, frame: &frame) == UInt16(IrqOffPath.otherException))

        frame.esr = 0x15 << 26
        #expect(IrqOffStretch.path(of: .irq, frame: &frame) == UInt16(IrqOffPath.interrupt))
    }


    @Test("a closed stretch is folded into its path and into the overall worst")
    func openCloseFolds() {
        withStretchState {
            IrqOffStretch.open(path: 13, at: 1_000)
            #expect(IrqOffStretch.close(at: 1_750) == 13)

            #expect(IrqOffStretch.longest == 750)
            #expect(IrqOffStretch.longestPath == 13)
            #expect(IrqOffStretch.longest(onPath: 13) == 750)

            // A shorter stretch elsewhere moves neither the overall worst nor
            // its path, and is still that path's own worst.
            IrqOffStretch.open(path: 64, at: 2_000)
            IrqOffStretch.close(at: 2_100)

            #expect(IrqOffStretch.longest == 750)
            #expect(IrqOffStretch.longestPath == 13)
            #expect(IrqOffStretch.longest(onPath: 64) == 100)

            // A shorter stretch on the same path does not lower its record.
            IrqOffStretch.open(path: 13, at: 3_000)
            IrqOffStretch.close(at: 3_010)
            #expect(IrqOffStretch.longest(onPath: 13) == 750)

            // A longer one moves both.
            IrqOffStretch.open(path: 64, at: 4_000)
            IrqOffStretch.close(at: 5_000)
            #expect(IrqOffStretch.longest == 1_000)
            #expect(IrqOffStretch.longestPath == 64)
        }
    }


    @Test("closing with nothing open files nothing, and a stretch closes once")
    func closeWithoutOpen() {
        withStretchState {
            #expect(IrqOffStretch.close(at: 9_000) == nil)
            #expect(IrqOffStretch.longest == 0)

            IrqOffStretch.open(path: 2, at: 100)
            #expect(IrqOffStretch.close(at: 400) == 2)

            // The idle-loop site closes, and the exception's exit would close
            // again; the second must not file the stretch from 100 to 9000.
            #expect(IrqOffStretch.close(at: 9_000) == nil)
            #expect(IrqOffStretch.longest == 300)
        }
    }


    @Test("a counter behind the opening reads as zero, not as a wrap")
    func backwardsCounter() {
        withStretchState {
            IrqOffStretch.open(path: 5, at: 1_000)
            IrqOffStretch.close(at: 10)
            #expect(IrqOffStretch.longest == 0)
        }
    }


    @Test("every path has a slot, and one past them is dropped")
    func tableCoversEveryPath() {
        withStretchState {
            for path in 0..<IrqOffPath.count {
                IrqOffStretch.fold(UInt64(path + 1), path: UInt16(path))
            }
            for path in 0..<IrqOffPath.count {
                #expect(IrqOffStretch.longest(onPath: UInt16(path)) == UInt32(path + 1))
            }

            IrqOffStretch.fold(1_000_000, path: UInt16(IrqOffPath.count))
            #expect(IrqOffStretch.longest(onPath: UInt16(IrqOffPath.count)) == 0)
        }
    }


    @Test("a path's record saturates, the overall worst keeps every bit")
    func saturation() {
        withStretchState {
            let huge = UInt64(UInt32.max) + 77
            IrqOffStretch.fold(huge, path: 9)

            #expect(IrqOffStretch.longest(onPath: 9) == UInt32.max)
            #expect(IrqOffStretch.longest == huge)
        }
    }


    @Test("a trace record is filed when a path's worst grows, and only then")
    func traceOnGrowth() {
        withStretchState {
            IrqOffStretch.fold(100, path: 3)
            IrqOffStretch.fold(50,  path: 3)
            IrqOffStretch.fold(100, path: 3)
            IrqOffStretch.fold(200, path: 3)
            IrqOffStretch.fold(10,  path: 4)

            var records: [TraceEvent] = []
            TraceRing.forEachEvent { event in
                if event.code == TraceCode.irqOff { records.append(event) }
            }

            #expect(records.map(\.info) == [3, 3, 4])
            #expect(records.map(\.a)    == [100, 200, 10])
        }
    }


    @Test("a preemption window ends the stretch and reopens it on the same path")
    func windowSplitsTheStretch() {
        withStretchState {
            host_set_virtual_counter(1_000)
            IrqOffStretch.open(path: 7, at: 1_000)

            // Three steps of 100 units each. On the host the budget is zero, so
            // a window opens after every step that leaves work behind.
            _ = Preemption.run(
                AddressSpaceTeardown.self,
                ClockedSteps(remaining: 3, cost: 100)
            )

            #expect(IrqOffStretch.close(at: 1_300) == 7)

            // Without the split the whole 300 would be one stretch.
            #expect(IrqOffStretch.longest(onPath: 7) == 100)
            #expect(IrqOffStretch.longest == 100)
        }
    }


    @Test("a window outside any exception leaves no stretch behind")
    func windowOutsideException() {
        withStretchState {
            host_set_virtual_counter(500)

            _ = Preemption.run(
                AddressSpaceTeardown.self,
                ClockedSteps(remaining: 3, cost: 100)
            )

            #expect(IrqOffStretch.close(at: 10_000) == nil)
            #expect(IrqOffStretch.longest == 0)
        }
    }


    /// 1 MHz makes the 200 µs budget 200 units. The exception has been masked
    /// for 1 000 when the run starts, so its first probe owes a window although
    /// the run itself has spent only 10.
    @Test("a run behind a long prologue opens its window at the first probe")
    func budgetCountsTheWholeException() {
        withStretchState {
            host_set_counter_frequency(1_000_000)
            defer { host_set_counter_frequency(0) }
            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            IrqOffStretch.open(path: 0, at: 1_000)
            host_set_virtual_counter(2_000)

            _ = Preemption.run(
                AddressSpaceTeardown.self,
                ClockedSteps(remaining: 2, cost: 10)
            )

            #expect(PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints == 1)
            #expect(IrqOffStretch.longest(onPath: 0) == 1_010)
        }
    }


    @Test("outside an exception the budget is the run's own, and a short run opens nothing")
    func budgetOutsideException() {
        withStretchState {
            host_set_counter_frequency(1_000_000)
            defer { host_set_counter_frequency(0) }
            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            host_set_virtual_counter(2_000)

            _ = Preemption.run(
                AddressSpaceTeardown.self,
                ClockedSteps(remaining: 2, cost: 10)
            )

            #expect(PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints == 0)
        }
    }


    // MARK: - Fixtures

    private func withStretchState(_ body: () -> Void) {
        withKernelTestGlobals {
            let mask = Trace.runtimeMask
            Trace.runtimeMask = 0x3F
            IrqOffStretch.reset()
            TraceRing.reset()
            host_set_virtual_counter(0)

            defer {
                IrqOffStretch.reset()
                TraceRing.reset()
                host_set_virtual_counter(0)
                Trace.runtimeMask = mask
            }

            body()
        }
    }
}
}


/// A step that costs `cost` counter units of the shim's clock and nothing else.
private struct ClockedSteps: ResumableOperation {

    typealias Failure = Never

    var remaining: Int
    let cost     : UInt64

    mutating func step() -> Progress {
        host_set_virtual_counter(Arch.Timer.counter() + cost)
        remaining -= 1

        return remaining > 0 ? .more : .done
    }
}
