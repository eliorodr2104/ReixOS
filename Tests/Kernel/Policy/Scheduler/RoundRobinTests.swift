//
//  RoundRobinTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelHostShims
import KernelTestSupport

/// The wake policy and the per-process quantum, over a real `RoundRobin`.
///
/// The current process lives in the shim's stand-in for `TPIDR_EL1`, so every
/// test runs under the global fixture lock and leaves it cleared.
extension KernelPolicyTestRoot {
@Suite("Round-robin wake policy", .serialized)
struct RoundRobinTests {

    private static let quantum = RoundRobin.quantum


    // MARK: - Admission and the tick

    @Test("a new process joins the tail with a whole quantum, and only a new one")
    func addTask() {
        withScheduler(3) { scheduler, processes in
            let a = processes[0], b = processes[1], c = processes[2]

            #expect(throws: Never.self) { try scheduler.addTask(a) }
            #expect(throws: Never.self) { try scheduler.addTask(b) }

            #expect(a.pointee.quantumLeft == Self.quantum)
            #expect(!scheduler.needsResched)

            // Already queued: refused, and the queue is not touched twice.
            #expect(throws: SchedulerError.notNewerProcess) { try scheduler.addTask(a) }

            c.pointee.status = .waiting
            #expect(throws: SchedulerError.notNewerProcess) { try scheduler.addTask(c) }

            #expect(scheduler.selectNextTask() == a)
            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == b)
        }
    }


    @Test("a tick spends only the running process's quantum and asks when it is gone")
    func tickChargesTheRunner() {
        withScheduler(2) { scheduler, processes in
            let a = processes[0], b = processes[1]
            admit(&scheduler, a, b)

            #expect(scheduler.selectNextTask() == a)

            for spent in 1..<Int(Self.quantum) {
                let asked = scheduler.onTick()
                #expect(!asked, "asked after \(spent) ticks")
            }

            let spentNow = scheduler.onTick()
            #expect(spentNow)
            #expect(a.pointee.quantumLeft == 0)
            #expect(b.pointee.quantumLeft == Self.quantum)

            // Spent stays spent: a tick that lands before the switch cannot wrap.
            let stillSpent = scheduler.onTick()
            #expect(stillSpent)
            #expect(a.pointee.quantumLeft == 0)
            #expect(scheduler.systemTicks == UInt64(Self.quantum) + 1)
        }
    }


    @Test("with nobody running, every tick asks")
    func idleTickAsks() {
        withScheduler(1) { scheduler, _ in
            #expect(scheduler.selectNextTask() == nil)
            let first  = scheduler.onTick()
            let second = scheduler.onTick()
            #expect(first && second)
        }
    }


    @Test("a spent process goes behind every ready one, with a fresh quantum")
    func expiryGoesToTheTail() {
        withScheduler(3) { scheduler, processes in
            let a = processes[0], b = processes[1], c = processes[2]
            admit(&scheduler, a, b, c)

            #expect(scheduler.selectNextTask() == a)
            spend(&scheduler, ticks: Int(Self.quantum))

            #expect(scheduler.selectNextTask() == b)
            #expect(a.pointee.quantumLeft == Self.quantum)

            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == c)

            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == a)
        }
    }


    @Test("a lone process whose quantum ran out runs again, refilled")
    func loneProcessRefills() {
        withScheduler(1) { scheduler, processes in
            let a = processes[0]
            admit(&scheduler, a)

            #expect(scheduler.selectNextTask() == a)
            spend(&scheduler, ticks: Int(Self.quantum))

            #expect(scheduler.selectNextTask() == a)
            #expect(a.pointee.quantumLeft == Self.quantum)
        }
    }


    // MARK: - Wakes

    @Test("a woken process with quantum left goes first and asks for the switch")
    func wakeWithRemainderGoesFirst() {
        withScheduler(4) { scheduler, processes in
            let a = processes[0], b = processes[1], c = processes[2], d = processes[3]
            admit(&scheduler, d, a, b, c)

            #expect(scheduler.selectNextTask() == d)
            spend(&scheduler, ticks: 3)
            parkCurrent(&scheduler, d)

            #expect(Arch.CPU.getCurrentProcess() == a)
            #expect(!scheduler.needsResched)

            scheduler.resume(d)

            #expect(scheduler.needsResched)
            #expect(d.pointee.quantumLeft == Self.quantum - 3)

            // Ahead of b and c, which were ready all along.
            #expect(scheduler.selectNextTask() == d)
            #expect(!scheduler.needsResched)
            #expect(d.pointee.quantumLeft == Self.quantum - 3)
        }
    }


    @Test("a woken process with its quantum spent waits its turn and asks nothing")
    func wakeWithoutRemainderGoesLast() {
        withScheduler(3) { scheduler, processes in
            let a = processes[0], b = processes[1], d = processes[2]
            admit(&scheduler, d, a, b)

            #expect(scheduler.selectNextTask() == d)
            spend(&scheduler, ticks: Int(Self.quantum))

            // The request the spent quantum raised is still pending when d
            // blocks, which is the case: d parks with nothing left.
            parkCurrent(&scheduler, d)
            #expect(Arch.CPU.getCurrentProcess() == a)

            scheduler.resume(d)

            #expect(!scheduler.needsResched)
            #expect(d.pointee.quantumLeft == Self.quantum)

            // Behind b, which was ready first, and ahead of a's next turn.
            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == b)
            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == d)
        }
    }


    @Test("wakeUp by pid follows the same policy, and refuses a pid not waiting")
    func wakeUpByPid() {
        withScheduler(3) { scheduler, processes in
            let a = processes[0], b = processes[1], d = processes[2]
            admit(&scheduler, d, a, b)

            #expect(scheduler.selectNextTask() == d)
            spend(&scheduler, ticks: 1)
            parkCurrent(&scheduler, d)
            #expect(Arch.CPU.getCurrentProcess() == a)

            #expect(throws: SchedulerError.processNotExist) { try scheduler.wakeUp(b.pointee.pid) }
            #expect(!scheduler.needsResched)

            #expect(throws: Never.self) { try scheduler.wakeUp(d.pointee.pid) }
            #expect(scheduler.needsResched)
            #expect(scheduler.selectNextTask() == d)

            #expect(throws: SchedulerError.processNotExist) { try scheduler.wakeUp(d.pointee.pid) }
        }
    }


    @Test("a process preempted by a wake keeps its place and its remainder")
    func preemptedKeepsItsPlace() {
        withScheduler(3) { scheduler, processes in
            let a = processes[0], b = processes[1], d = processes[2]
            admit(&scheduler, d, a, b)

            #expect(scheduler.selectNextTask() == d)
            parkCurrent(&scheduler, d)

            #expect(Arch.CPU.getCurrentProcess() == a)
            spend(&scheduler, ticks: 2)

            scheduler.resume(d)
            #expect(scheduler.selectNextTask() == d)
            parkCurrent(&scheduler, d)

            // a was cut short by d, not by its quantum: it resumes before b.
            #expect(Arch.CPU.getCurrentProcess() == a)
            #expect(a.pointee.quantumLeft == Self.quantum - 2)

            spend(&scheduler, ticks: Int(Self.quantum) - 2)
            #expect(scheduler.selectNextTask() == b)
        }
    }


    @Test("yield gives up the rest of the quantum and goes behind the others")
    func yieldSurrendersTheRemainder() {
        withScheduler(2) { scheduler, processes in
            let a = processes[0], b = processes[1]
            admit(&scheduler, a, b)

            #expect(scheduler.selectNextTask() == a)
            spend(&scheduler, ticks: 2)

            _ = scheduler.yield()
            #expect(Arch.CPU.getCurrentProcess() == b)
            #expect(a.pointee.quantumLeft == Self.quantum)

            _ = scheduler.yield()
            #expect(Arch.CPU.getCurrentProcess() == a)
        }
    }


    @Test("blocking keeps the remainder, and the yield that follows does not spend it")
    func blockKeepsTheRemainder() {
        withScheduler(2) { scheduler, processes in
            let a = processes[0], b = processes[1]
            admit(&scheduler, a, b)

            #expect(scheduler.selectNextTask() == a)
            spend(&scheduler, ticks: 4)

            #expect(throws: Never.self) { try scheduler.block(a.pointee.pid) }
            _ = scheduler.yield()

            #expect(Arch.CPU.getCurrentProcess() == b)
            #expect(a.pointee.quantumLeft == Self.quantum - 4)

            // The wrong pid is refused rather than blocking somebody else.
            #expect(throws: SchedulerError.processNotExist) { try scheduler.block(a.pointee.pid) }
            #expect(Arch.CPU.getCurrentProcess() == b)
        }
    }


    @Test("waking a process that is not waiting changes nothing")
    func wakeOfTheAwakeIsInert() {
        withScheduler(3) { scheduler, processes in
            let a = processes[0], b = processes[1], c = processes[2]
            admit(&scheduler, a, b)

            #expect(scheduler.selectNextTask() == a)

            scheduler.resume(a)
            scheduler.resume(b)
            #expect(!scheduler.needsResched)

            c.pointee.status = .terminated
            scheduler.resume(c)
            #expect(!scheduler.needsResched)
            if case .terminated = c.pointee.status {} else { Issue.record("a corpse was put back to work") }

            // The queue is what it was: b next, then a, each exactly once.
            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == b)
            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == a)
        }
    }


    @Test("two wakes in one go run in the order they came, before the one they preempted")
    func twoWakesAreLastInFirstOut() {
        withScheduler(4) { scheduler, processes in
            let a = processes[0], b = processes[1], d = processes[2], e = processes[3]
            admit(&scheduler, d, e, a, b)

            #expect(scheduler.selectNextTask() == d)
            parkCurrent(&scheduler, d)
            #expect(Arch.CPU.getCurrentProcess() == e)
            parkCurrent(&scheduler, e)
            #expect(Arch.CPU.getCurrentProcess() == a)

            scheduler.resume(d)
            scheduler.resume(e)

            #expect(scheduler.selectNextTask() == d)
            parkCurrent(&scheduler, d)
            #expect(Arch.CPU.getCurrentProcess() == e)
            parkCurrent(&scheduler, e)

            // a, cut short, before b, which has only been ready.
            #expect(Arch.CPU.getCurrentProcess() == a)
            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == b)
        }
    }


    @Test("a rotation with no wake to make way for leaves the running process on")
    func noWakeNoPreemption() {
        withScheduler(2) { scheduler, processes in
            let a = processes[0], b = processes[1]
            admit(&scheduler, a, b)

            #expect(scheduler.selectNextTask() == a)
            spend(&scheduler, ticks: 2)

            #expect(scheduler.selectNextTask() == a)
            #expect(a.pointee.quantumLeft == Self.quantum - 2)
        }
    }


    @Test("a woken process killed before the switch hands its place back")
    func unlinkedWakeIsForgotten() {
        withScheduler(5) { scheduler, processes in
            let a = processes[0], b = processes[1], d = processes[2], e = processes[3], f = processes[4]
            admit(&scheduler, d, e, f, a, b)

            #expect(scheduler.selectNextTask() == d)
            parkCurrent(&scheduler, d)
            parkCurrent(&scheduler, e)
            parkCurrent(&scheduler, f)
            #expect(Arch.CPU.getCurrentProcess() == a)

            scheduler.resume(d)
            scheduler.resume(e)
            scheduler.resume(f)

            // The newest and a middle one die before the switch.
            scheduler.unlink(f, in: .ready)
            scheduler.unlink(e, in: .ready)
            f.pointee.status = .terminated
            e.pointee.status = .terminated

            #expect(scheduler.selectNextTask() == d)
            parkCurrent(&scheduler, d)
            #expect(Arch.CPU.getCurrentProcess() == a)
            #expect(a.pointee.quantumLeft == Self.quantum)

            // The only wake dies: nothing to make way for, a stays on.
            scheduler.resume(d)
            scheduler.unlink(d, in: .ready)
            d.pointee.status = .terminated
            #expect(scheduler.needsResched)
            #expect(scheduler.selectNextTask() == a)

            spend(&scheduler, ticks: Int(Self.quantum))
            #expect(scheduler.selectNextTask() == b)
        }
    }


    // MARK: - Starvation

    /// A ready process waits at most the sum of everybody else's remainders,
    /// because only the tail refills and nothing that reaches the tail can get
    /// ahead of it again. For a CPU-bound process against one ping-pong pair
    /// that is two quanta, however often the pair wake each other.
    @Test("a ping-pong pair cannot keep a CPU-bound process off the CPU for more than two quanta",
          arguments: [1, 3, 64])
    func pingPongCannotStarve(handoffsPerTick: Int) {
        withScheduler(3) { scheduler, processes in
            let spinner = processes[0], ping = processes[1], pong = processes[2]
            admit(&scheduler, ping, pong, spinner)

            let result = simulate(
                &scheduler,
                ticks         : 2_000,
                stepsPerTick  : handoffsPerTick,
                roles         : [spinner: .spin, ping: .handOff(to: pong), pong: .handOff(to: ping)],
                watched       : [spinner]
            )

            let bound = 2 * Int(Self.quantum)
            #expect(result.longestWait[spinner, default: .max] <= bound)

            // The worst case is the steady state, so the share is a third.
            #expect(result.ran[spinner, default: 0] * 3 >= 2_000 - bound)
        }
    }


    /// Five processes that each want the CPU, a ping-pong pair among them, and
    /// an interrupt-driven one woken on every tick. Each CPU-bound one waits at
    /// most `(n - 1)` quanta; the woken one runs at the very next switch.
    @Test("under mixed load every CPU-bound process waits at most (n - 1) quanta")
    func mixedLoadBound() {
        withScheduler(6) { scheduler, processes in
            let spinners = Array(processes[0..<3])
            let ping = processes[3], pong = processes[4], driver = processes[5]
            admit(&scheduler, spinners[0], ping, spinners[1], pong, spinners[2], driver)

            var roles: [UnsafeMutablePointer<Process>: Role] = [
                ping: .handOff(to: pong), pong: .handOff(to: ping), driver: .blockAtOnce,
            ]
            for spinner in spinners { roles[spinner] = .spin }

            let result = simulate(
                &scheduler,
                ticks         : 3_000,
                stepsPerTick  : 16,
                roles         : roles,
                watched       : spinners,
                interruptWakes: driver
            )

            let bound = (processes.count - 1) * Int(Self.quantum)
            for spinner in spinners {
                #expect(result.longestWait[spinner, default: .max] <= bound)
                #expect(result.ran[spinner, default: 0] > 0)
            }

            // Run at the switch the waking tick asks for, unless ticks landing on
            // it spent its quantum, which takes a whole quantum of them per miss.
            #expect(result.driverWakes > 2_000)
            #expect(result.driverLateSwitches <= result.ran[driver, default: 0] / Int(Self.quantum))
            #expect(result.driverLateSwitches * 50 < result.driverWakes)
        }
    }


    // MARK: - Simulation

    private enum Role {

        /// Never blocks.
        case spin

        /// Wakes its partner if it is waiting, then blocks: one side of a
        /// call and reply.
        case handOff(to: UnsafeMutablePointer<Process>)

        /// Blocks the moment it runs, the way a driver goes back to waiting.
        case blockAtOnce
    }


    private struct SimulationResult {
        var longestWait: [UnsafeMutablePointer<Process>: Int] = [:]
        var ran        : [UnsafeMutablePointer<Process>: Int] = [:]
        var driverWakes        = 0
        var driverLateSwitches = 0
    }


    /// Runs the machine for `ticks` ticks of `stepsPerTick` steps each.
    ///
    /// A step is the current process doing what its role says; after it, the
    /// way back to EL0 honours `needsResched` exactly as `performPendingSwitch`
    /// does. Each tick charges the runner, asks for the switch a spent quantum
    /// needs and, with `interruptWakes`, wakes that process as a device would.
    /// Waits are counted in ticks spent ready and not running.
    private func simulate(
        _ scheduler   : inout RoundRobin,
        ticks         : Int,
        stepsPerTick  : Int,
        roles         : [UnsafeMutablePointer<Process>: Role],
        watched       : [UnsafeMutablePointer<Process>],
        interruptWakes: UnsafeMutablePointer<Process>? = nil
    ) -> SimulationResult {
        var result  = SimulationResult()
        var waiting : [UnsafeMutablePointer<Process>: Int] = [:]

        _ = scheduler.selectNextTask()

        for _ in 0..<ticks {
            for _ in 0..<stepsPerTick {
                guard let current = Arch.CPU.getCurrentProcess() else {
                    _ = scheduler.selectNextTask()
                    continue
                }

                switch roles[current] {
                    case .handOff(let partner):
                        if case .waiting = partner.pointee.status { scheduler.resume(partner) }
                        parkCurrent(&scheduler, current)

                    case .blockAtOnce:
                        parkCurrent(&scheduler, current)

                    case .spin, .none:
                        break
                }

                if scheduler.needsResched { _ = scheduler.selectNextTask() }
            }

            let runner = Arch.CPU.getCurrentProcess()
            if let runner { result.ran[runner, default: 0] += 1 }

            for process in watched {
                if case .ready = process.pointee.status {
                    waiting[process, default: 0] += 1
                    result.longestWait[process] = max(result.longestWait[process, default: 0], waiting[process]!)
                } else {
                    waiting[process] = 0
                }
            }

            if scheduler.onTick() { scheduler.requestReschedule() }

            var woke = false
            if let driver = interruptWakes, case .waiting = driver.pointee.status {
                scheduler.resume(driver)
                result.driverWakes += 1
                woke = true
            }

            if scheduler.needsResched { _ = scheduler.selectNextTask() }

            if woke, let driver = interruptWakes, Arch.CPU.getCurrentProcess() != driver {
                result.driverLateSwitches += 1
            }
        }

        return result
    }


    // MARK: - Fixtures

    private func withScheduler(
        _ count: Int,
        _ body : (inout RoundRobin, [UnsafeMutablePointer<Process>]) -> Void
    ) {
        withProcesses(count) { processes in
            Arch.CPU.setCurrentProcess(0)
            defer { Arch.CPU.setCurrentProcess(0) }

            var scheduler = RoundRobin()
            body(&scheduler, processes)
        }
    }


    private func admit(_ scheduler: inout RoundRobin, _ processes: UnsafeMutablePointer<Process>...) {
        for process in processes {
            #expect(throws: Never.self) { try scheduler.addTask(process) }
        }
    }


    /// Ticks the running process `ticks` times, as the timer would.
    private func spend(_ scheduler: inout RoundRobin, ticks: Int) {
        for _ in 0..<ticks {
            if scheduler.onTick() { scheduler.requestReschedule() }
        }
    }


    /// Blocks the running process and switches away, the way a blocking
    /// syscall ends.
    private func parkCurrent(_ scheduler: inout RoundRobin, _ process: UnsafeMutablePointer<Process>) {
        #expect(throws: Never.self) { try scheduler.block(process.pointee.pid) }
        _ = scheduler.yield()
    }
}
}
