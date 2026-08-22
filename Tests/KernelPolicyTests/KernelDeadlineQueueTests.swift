//
//  KernelDeadlineQueueTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

@Suite("Kernel deadline queue")
struct KernelDeadlineQueueTests {
    @Test("empty and future polls inspect only the heap root")
    func noGlobalScan() {
        var empty = KernelDeadlineQueue()
        #expect(empty.poll(now: 1, budget: 8) { _, _ in } == 0)
        #expect(empty.inspectionCount == 0)

        withProcesses(128) { processes in
            var queue = KernelDeadlineQueue()
            for (offset, process) in processes.enumerated() {
                let armed = queue.arm(process, kind: .ipc, deadline: UInt64(10_000 + offset))
                #expect(armed)
            }

            queue.resetInspectionCount()
            #expect(queue.poll(now: 9_999, budget: 8) { _, _ in } == 0)
            #expect(queue.inspectionCount == 1)
        }
    }

    @Test("cancel and rearm cannot deliver a stale expiration or double wake")
    func transitionRearm() {
        withProcesses(1) { processes in
            let process = processes[0]
            var queue = KernelDeadlineQueue()

            let firstArm = queue.arm(process, kind: .ipc, deadline: 10)
            let cancelled = queue.cancel(process)
            let secondArm = queue.arm(process, kind: .sleep, deadline: 20)
            #expect(firstArm && cancelled && secondArm)

            var kinds: [KernelDeadlineKind] = []
            #expect(queue.poll(now: 10, budget: 8) { _, kind in kinds.append(kind) } == 0)
            #expect(queue.poll(now: 20, budget: 8) { _, kind in kinds.append(kind) } == 1)
            #expect(kinds == [.sleep])

            // #expect's autoclosure captures `queue` as immutable, so the
            // mutating call must happen in a plain statement first.
            let cancelledAgain = queue.cancel(process)
            #expect(!cancelledAgain)
        }
    }

    @Test("equal deadlines expire in insertion order")
    func stableEqualDeadlines() {
        withProcesses(4) { processes in
            var queue = KernelDeadlineQueue()
            for process in processes {
                let armed = queue.arm(process, kind: .ipc, deadline: 50)
                #expect(armed)
            }

            var expired: [PID] = []
            #expect(queue.poll(now: 50, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 4)
            #expect(expired == [1, 2, 3, 4])
        }
    }

    @Test("deadlines preserve order across UInt64 wrap")
    func counterWrap() {
        withProcesses(3) { processes in
            var queue = KernelDeadlineQueue()
            let first = queue.arm(processes[0], kind: .sleep, deadline: UInt64.max - 1)
            let second = queue.arm(processes[1], kind: .ipc, deadline: 1)
            let third = queue.arm(processes[2], kind: .sleep, deadline: 3)
            #expect(first && second && third)

            var expired: [PID] = []
            #expect(queue.poll(now: UInt64.max - 1, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 1)
            #expect(queue.poll(now: 1, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 1)
            #expect(queue.poll(now: 3, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 1)
            #expect(expired == [1, 2, 3])
        }
    }

    @Test("cancelling the head and a middle node cannot expire them")
    func cancelHeadAndMiddle() {
        withProcesses(5) { processes in
            var queue = KernelDeadlineQueue()
            for (offset, process) in processes.enumerated() {
                let armed = queue.arm(process, kind: .ipc, deadline: UInt64(10 + offset))
                #expect(armed)
            }

            let cancelledHead = queue.cancel(processes[0])
            let cancelledMiddle = queue.cancel(processes[3])
            let cancelledTwice = queue.cancel(processes[3])
            #expect(cancelledHead)
            #expect(cancelledMiddle)
            #expect(!cancelledTwice)

            var expired: [PID] = []
            #expect(queue.poll(now: 20, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 3)
            #expect(expired == [2, 3, 5])
        }
    }

    @Test("expiration budget leaves due work armed for the next poll")
    func budgetResume() {
        withProcesses(20) { processes in
            var queue = KernelDeadlineQueue()
            for process in processes {
                let armed = queue.arm(process, kind: .ipc, deadline: 7)
                #expect(armed)
            }

            var expired: [PID] = []
            #expect(queue.poll(now: 7, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 8)
            #expect(queue.hasDue(at: 7))
            #expect(queue.poll(now: 7, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 8)
            #expect(queue.poll(now: 7, budget: 8) { process, _ in
                expired.append(process.pointee.pid)
            } == 4)
            #expect(expired == Array(1...20).map(PID.init))
            #expect(!queue.hasDue(at: 7))
        }
    }

    @Test("capacity failure is clean and a cancelled slot is reusable")
    func boundedCapacity() {
        withProcesses(KernelDeadlineQueue.capacity + 1) { processes in
            var queue = KernelDeadlineQueue()
            for process in processes.prefix(KernelDeadlineQueue.capacity) {
                let armed = queue.arm(process, kind: .ipc, deadline: 100)
                #expect(armed)
            }

            let overflow = queue.arm(processes.last!, kind: .ipc, deadline: 100)
            #expect(!overflow)
            #expect(processes.last!.pointee.kernelDeadlineKind == .none)

            let cancelled = queue.cancel(processes[500])
            let reused = queue.arm(processes.last!, kind: .ipc, deadline: 100)
            #expect(cancelled)
            #expect(reused)
        }
    }

    @Test("cancel before process teardown leaves no stale pointer")
    func teardownCancellation() {
        let process = makeProcess(pid: 42)
        var queue = KernelDeadlineQueue()
        let armed = queue.arm(process, kind: .ipc, deadline: 1)
        let cancelled = queue.cancel(process)
        #expect(armed)
        #expect(cancelled)

        destroyProcess(process)

        #expect(queue.poll(now: 1, budget: 8) { _, _ in
            Issue.record("cancelled process expired")
        } == 0)
    }
}
