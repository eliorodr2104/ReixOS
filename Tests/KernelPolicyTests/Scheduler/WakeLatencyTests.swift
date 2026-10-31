//
//  WakeLatencyTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelHostShims
import KernelTestSupport

/// Wake-to-run and deadline lag, measured against the shim's staged counter.
///
/// `WakeLatency`, the trace ring, the deadline queue and the counter are all
/// global; every test starts them from zero and leaves them there.
extension KernelPolicyTestRoot {
@Suite("Wake latency", .serialized)
struct WakeLatencyTests {

    @Test("a wake is measured from the wake to the rotation that runs it")
    func wakeToRun() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], d = processes[1]
            admitAndPark(&scheduler, d, then: a)

            host_set_virtual_counter(1_000)
            scheduler.resume(d)

            host_set_virtual_counter(1_700)
            #expect(scheduler.selectNextTask() == d)

            #expect(WakeLatency.longestWake == 700)
            #expect(WakeLatency.longestDeadlineLag == 0)
            #expect(d.pointee.readyCause == .none)

            let records = traced(TraceCode.wakeRun)
            #expect(records.map(\.a) == [700])
            #expect(records.map(\.pid) == [UInt32(d.pointee.pid)])
        }
    }


    @Test("a shorter wake later does not lower the worst one")
    func worstIsKept() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], d = processes[1]
            admitAndPark(&scheduler, d, then: a)

            host_set_virtual_counter(100)
            scheduler.resume(d)
            host_set_virtual_counter(600)
            #expect(scheduler.selectNextTask() == d)

            parkCurrent(&scheduler, d)

            host_set_virtual_counter(1_000)
            scheduler.resume(d)
            host_set_virtual_counter(1_010)
            #expect(scheduler.selectNextTask() == d)

            #expect(WakeLatency.longestWake == 500)
            #expect(traced(TraceCode.wakeRun).map(\.a) == [500, 10])
        }
    }


    @Test("admission, preemption and yield are not wakes and measure nothing")
    func onlyWakesAreMeasured() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], b = processes[1]

            host_set_virtual_counter(10)
            #expect(throws: Never.self) { try scheduler.addTask(a) }
            #expect(throws: Never.self) { try scheduler.addTask(b) }

            host_set_virtual_counter(5_000)
            #expect(scheduler.selectNextTask() == a)
            _ = scheduler.yield()
            host_set_virtual_counter(9_000)
            _ = scheduler.yield()

            #expect(WakeLatency.longestWake == 0)
            #expect(traced(TraceCode.wakeRun).isEmpty)
        }
    }


    @Test("a deadline is measured from when it was due, and only as a deadline")
    func deadlineLag() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], d = processes[1]
            admitAndPark(&scheduler, d, then: a)

            host_set_virtual_counter(5_000)
            scheduler.resume(d)
            WakeLatency.backdate(d, to: 4_200)

            host_set_virtual_counter(5_300)
            #expect(scheduler.selectNextTask() == d)

            #expect(WakeLatency.longestDeadlineLag == 1_100)
            #expect(WakeLatency.longestWake == 0)
            #expect(traced(TraceCode.deadlineLag).map(\.a) == [1_100])
            #expect(traced(TraceCode.wakeRun).isEmpty)
        }
    }


    @Test("backdating refuses a process the expiry did not make ready")
    func backdateRefusals() {
        withLatencyState(3) { scheduler, processes in
            let a = processes[0], d = processes[1], b = processes[2]
            admitAndPark(&scheduler, d, then: a)
            #expect(throws: Never.self) { try scheduler.addTask(b) }

            // Still waiting: the expiry found it gone, or did not wake it.
            WakeLatency.backdate(d, to: 1)
            #expect(d.pointee.readyCause == .none)

            // Running, and ready without a wake to measure, as a new process is.
            WakeLatency.backdate(a, to: 1)
            #expect(a.pointee.readyCause == .none)
            WakeLatency.backdate(b, to: 1)
            #expect(b.pointee.readyCause == .none)

            // Woken, then filed: a second backdate does not move it again.
            host_set_virtual_counter(800)
            scheduler.resume(d)
            WakeLatency.backdate(d, to: 300)
            WakeLatency.backdate(d, to: 1)
            #expect(d.pointee.readySince == 300)
        }
    }


    @Test("a stamp later than the run reads as zero, not as a wrap")
    func backwardsClock() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], d = processes[1]
            admitAndPark(&scheduler, d, then: a)

            host_set_virtual_counter(9_000)
            scheduler.resume(d)
            host_set_virtual_counter(10)
            #expect(scheduler.selectNextTask() == d)

            #expect(WakeLatency.longestWake == 0)
        }
    }


    /// The whole path: a sleeper armed for tick 5, expired at tick 7 because
    /// two ticks went by before anyone polled. Tick 7 was due at 100 000 at
    /// 1 MHz and 10 ms a tick, so tick 5 was due 20 000 units earlier.
    @Test("an expiry a full budget left behind is dated to the tick it was due at")
    func checkTimeoutsBackdates() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], d = processes[1]
            admitAndPark(&scheduler, d, then: a)

            host_set_counter_frequency(1_000_000)
            defer { host_set_counter_frequency(0) }

            let ipc = allocateZeroedStorage(KernelIPC.self)
            defer { UnsafeMutableRawPointer(ipc).deallocate() }

            let armed = KernelDeadlineQueue.shared.arm(d, kind: .sleep, deadline: 5)
            #expect(armed)
            defer { _ = KernelDeadlineQueue.shared.cancel(d) }

            withUnsafeMutablePointer(to: &scheduler) { pointer in
                let saved: UnsafeMutablePointer<KernelScheduler>? = Kernel.scheduler
                Kernel.scheduler = pointer
                defer { Kernel.scheduler = saved }

                host_set_virtual_counter(100_400)
                ipc.pointee.checkTimeouts(now: 7, tickDue: 100_000)
            }

            #expect(d.pointee.readyCause == .deadline)
            #expect(d.pointee.readySince == 80_000)

            host_set_virtual_counter(100_900)
            #expect(scheduler.selectNextTask() == d)
            #expect(WakeLatency.longestDeadlineLag == 20_900)
        }
    }


    @Test("an expiry due this tick is dated to this tick")
    func checkTimeoutsOnTime() {
        withLatencyState(2) { scheduler, processes in
            let a = processes[0], d = processes[1]
            admitAndPark(&scheduler, d, then: a)

            host_set_counter_frequency(1_000_000)
            defer { host_set_counter_frequency(0) }

            let ipc = allocateZeroedStorage(KernelIPC.self)
            defer { UnsafeMutableRawPointer(ipc).deallocate() }

            let armed = KernelDeadlineQueue.shared.arm(d, kind: .sleep, deadline: 7)
            #expect(armed)
            defer { _ = KernelDeadlineQueue.shared.cancel(d) }

            withUnsafeMutablePointer(to: &scheduler) { pointer in
                let saved: UnsafeMutablePointer<KernelScheduler>? = Kernel.scheduler
                Kernel.scheduler = pointer
                defer { Kernel.scheduler = saved }

                host_set_virtual_counter(100_400)
                ipc.pointee.checkTimeouts(now: 7, tickDue: 100_000)
            }

            #expect(d.pointee.readySince == 100_000)
        }
    }


    // MARK: - Fixtures

    private func withLatencyState(
        _ count: Int,
        _ body : (inout RoundRobin, [UnsafeMutablePointer<Process>]) -> Void
    ) {
        withProcesses(count) { processes in
            let mask = Trace.runtimeMask
            Trace.runtimeMask = 0x3F
            WakeLatency.reset()
            TraceRing.reset()
            host_set_virtual_counter(0)
            Arch.CPU.setCurrentProcess(0)

            defer {
                Arch.CPU.setCurrentProcess(0)
                host_set_virtual_counter(0)
                TraceRing.reset()
                WakeLatency.reset()
                Trace.runtimeMask = mask
            }

            var scheduler = RoundRobin()
            body(&scheduler, processes)
        }
    }


    /// Admits both, runs `parked` and blocks it, leaving `runner` on the CPU
    /// and the ring empty.
    private func admitAndPark(
        _ scheduler: inout RoundRobin,
        _ parked   : UnsafeMutablePointer<Process>,
        then runner: UnsafeMutablePointer<Process>
    ) {
        #expect(throws: Never.self) { try scheduler.addTask(parked) }
        #expect(throws: Never.self) { try scheduler.addTask(runner) }
        #expect(scheduler.selectNextTask() == parked)
        parkCurrent(&scheduler, parked)
        #expect(Arch.CPU.getCurrentProcess() == runner)

        TraceRing.reset()
    }


    private func parkCurrent(_ scheduler: inout RoundRobin, _ process: UnsafeMutablePointer<Process>) {
        #expect(throws: Never.self) { try scheduler.block(process.pointee.pid) }
        _ = scheduler.yield()
    }


    private func traced(_ code: UInt16) -> [TraceEvent] {
        var records: [TraceEvent] = []
        TraceRing.forEachEvent { event in
            if event.code == code { records.append(event) }
        }
        return records
    }
}
}
