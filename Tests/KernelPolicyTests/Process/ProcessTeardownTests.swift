//
//  ProcessTeardownTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims
import ReixABI

/// `ProcessTeardown`, a death after publication as one operation. The suite
/// owns the order of its stages, which step each fact changes on, the single
/// run `killProcess` makes of it, and the corpse's two destinations.
///
/// The child holds one faulted anonymous page, an IPC deadline and capabilities
/// in slots 3 and 9, so the address space is six steps and the table three:
/// slot 3, slot 9, and the scan past the last slot that finishes it.
extension KernelPolicyTestRoot {
@Suite("Process teardown in steps", .serialized)
struct ProcessTeardownTests {

    @Test("to the terminated list: address space, waits, table, corpse, in that order")
    func toTerminatedList() {
        withDeath(parked: false) { death in
            let log = stepThrough(death)

            #expect(log == Array(repeating: [], count: 36) + [
                ["regions"], [], [], ["manager"], ["trapFrame"], ["invalidated"],
                [],
                ["caps"], ["caps"], [],
                ["zombie"]
            ])

            // Still whole, so a later reap can read it.
            #expect(death.child.pointee.metadata != nil)
            #expect(death.parent.pointee.family.findChild(id: death.pid) == death.child)
        }
    }


    @Test("to a parked parent: unlinked with its status, then the metadata, then freed and woken")
    func toParkedParent() {
        withDeath(parked: true) { death in
            let log = stepThrough(death)

            #expect(log == Array(repeating: [], count: 36) + [
                ["regions"], [], [], ["manager"], ["trapFrame"], ["invalidated"],
                [],
                ["caps"], ["caps"], [],
                ["unlinked", "claim", "status"],
                ["metadata"],
                ["freed", "woken"]
            ])

            #expect(death.parent.pointee.context?.pointee.x0 == 7)
        }
    }


    /// On the host the budget is zero, so a window follows every step that
    /// leaves work behind, including scans over empty prologue stages.
    @Test("killProcess makes one run of the death, with a window at every boundary",
          arguments: [false, true])
    func oneRun(parked: Bool) {
        withDeath(parked: parked) { death in
            let mask = Trace.runtimeMask
            Trace.runtimeMask = 0x3F
            TraceRing.reset()
            defer { TraceRing.reset(); Trace.runtimeMask = mask }

            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            let reachable = death.manager.pointee.killProcess(
                death.child,
                reason : .exited(7),
                context: death.context
            )

            let windows: UInt64 = parked ? 48 : 46

            #expect(reachable == !parked)
            #expect(PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints == windows)
            #expect(teardownSpans().map(\.b) == [windows])
        }
    }


    @Test("the corpse goes to the terminated list when nobody waits on it")
    func killToTerminatedList() {
        withDeath(parked: false) { death in
            #expect(death.manager.pointee.killProcess(
                death.child,
                reason : .exited(7),
                context: death.context
            ))

            #expect(death.context.scheduler.pointee.search(in: .terminated, to: death.pid) == death.child)
            #expect(ProcessManager.exitStatus(of: death.child) == 7)
            #expect(death.child.pointee.metadata.pointee.capsTable.caps[3] == nil)
            #expect(death.child.pointee.metadata.pointee.capsTable.caps[9] == nil)
            #expect(death.child.pointee.kernelDeadlineKind == .none)

            if case .waiting = death.parent.pointee.status {} else {
                Issue.record("a parent that was not waiting was moved")
            }
        }
    }


    @Test("the corpse goes to a parent parked in reapChild, which is woken with its status")
    func killToParkedParent() {
        withDeath(parked: true) { death in
            #expect(!death.manager.pointee.killProcess(
                death.child,
                reason : .exited(7),
                context: death.context
            ))

            #expect(death.context.scheduler.pointee.search(in: .terminated, to: death.pid) == nil)
            #expect(death.parent.pointee.family.findChild(id: death.pid) == nil)
            #expect(death.parent.pointee.metadata.pointee.waitingChildPid == nil)
            #expect(death.parent.pointee.context?.pointee.x0 == 7)

            if case .waiting = death.parent.pointee.status {
                Issue.record("the parked parent was never woken")
            }
        }
    }


    /// The `try?` the address space used to be released under: a table the PPM
    /// refuses ends that stage and nothing else.
    @Test("a root the PPM refuses does not stop the capabilities or the corpse")
    func refusedRootStopsNothingElse() {
        withDeath(parked: false) { death in
            let root  = death.child.pointee.addressSpace.rootTablePhysical
            let sound = death.ram.frame(at: root)

            death.ram.setFrame(
                FrameInfo(refCount: sound.refCount, order: sound.order, flags: []),
                at: root
            )

            #expect(death.manager.pointee.killProcess(
                death.child,
                reason : .exited(7),
                context: death.context
            ))

            #expect(death.child.pointee.metadata.pointee.capsTable.caps[3] == nil)
            #expect(death.child.pointee.metadata.pointee.capsTable.caps[9] == nil)
            #expect(death.context.scheduler.pointee.search(in: .terminated, to: death.pid) == death.child)

            death.ram.setFrame(sound, at: root)
            try? death.ram.ppm.pointee.freeOwnedKernelPage(PhysicalPage(address: root, order: 0))
        }
    }


    @Test("the first window sees a dead process on no live queue", arguments: [0, 1, 2, 3, 4])
    func dyingBeforeFirstWindow(queue: Int) {
        withDeath(parked: true) { death in
            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            let runnable = makeProcess(pid: 900)
            let runnableFrame = allocateZeroedStorage(Arch.TrapFrame.self)
            runnable.pointee.context = runnableFrame
            defer {
                destroyProcess(runnable)
                UnsafeMutableRawPointer(runnableFrame).deallocate()
            }
            switch queue {
                case 0: try? death.context.scheduler.pointee.addTask(death.child)
                case 1:
                    Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: death.child)))
                    try? death.context.scheduler.pointee.block(death.pid)
                    Arch.CPU.setCurrentProcess(0)
                case 2, 3:
                    death.child.pointee.status = queue == 2
                        ? .blockedOnSend(endpoint) : .blockedOnReceive(endpoint)
                    endpoint.pointee.state = queue == 2 ? .sendBlocked : .recvBlocked
                    endpoint.pointee.queue.pushBack(death.child)
                case 4:
                    try? death.context.scheduler.pointee.addTask(runnable)
                    _ = KernelDeadlineQueue.shared.cancel(death.child)
                    Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: death.child)))
                    death.child.pointee.status = .running
                    var frame = Arch.TrapFrame()
                    frame.x0 = 100
                    SleepSyscall.handle(frame: &frame, context: death.context)
                    #expect(death.child.pointee.kernelDeadlineKind == .sleep)
                    Arch.CPU.setCurrentProcess(0)
                default: break
            }

            var windows = 0
            DeathWindows.inspect = {
                windows += 1
                #expect(death.context.scheduler.pointee.search(in: .ready, to: death.pid) == nil)
                #expect(death.context.scheduler.pointee.search(in: .waiting, to: death.pid) == nil)
                #expect(endpoint.pointee.queue.isEmpty())
                #expect(death.parent.pointee.metadata.pointee.waitingChildPid == death.pid
                    || death.parent.pointee.family.findChild(id: death.pid) == nil)
                if death.parent.pointee.family.findChild(id: death.pid) != nil {
                    #expect(!death.manager.pointee.isAlive(identity: death.child.pointee.identity))
                    #expect(death.child.pointee.kernelDeadlineKind == .none)
                    death.context.ipc.pointee.checkTimeouts(now: 1_000_000, tickDue: 0)
                    death.context.scheduler.pointee.resume(death.child)
                    #expect(death.context.scheduler.pointee.search(in: .ready, to: death.pid) == nil)
                    #expect((death.context.scheduler.pointee.reapChild(death.child)) == false)
                }
            }
            host_set_interrupt_window_hook { DeathWindows.inspect?() }
            defer { host_set_interrupt_window_hook(nil); DeathWindows.inspect = nil }

            #expect(!death.manager.pointee.killProcess(death.child, reason: .exited(7), context: death.context))
            #expect(windows > 0)
            #expect(death.parent.pointee.context?.pointee.x0 == 7)
        }
    }

    @Test("owned tasks, zombies and reply waiters advance separately with balanced corpses", arguments: [false, true])
    func manyDependents(deep: Bool) {
        withDeath(parked: false, pages: 768) { death in
            var tasks: [(TaskControl, PID, Bool)] = []
            var zombies: [PID] = []
            var waiters: [UnsafeMutablePointer<Process>] = []
            let owner = death.child
            var budgets: [UnsafeMutablePointer<FrameBudget>] = []
            func holdBudget(of process: UnsafeMutablePointer<Process>) {
                if let budget = process.pointee.metadata?.pointee.budget {
                    rxRetain(budget)
                    budgets.append(budget)
                }
            }
            holdBudget(of: owner)
            defer {
                for budget in budgets { releaseBudget(budget, heap: death.manager.pointee.heap) }
            }

            var creator = owner
            for index in 0..<TaskRegistry.capacity {
                Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: creator)))
                guard let task = death.manager.pointee.createSuspendedTask(ownedBy: creator) else {
                    Issue.record("could not create dependent task"); return
                }
                TaskRegistry.retain(task.control)
                holdBudget(of: task.process)
                let running = index % 2 == 0
                if running {
                    death.manager.pointee.releaseConstruction(TaskRegistry.markRunning(task.control))
                    try? death.context.scheduler.pointee.addTask(task.process)
                }
                tasks.append((task.control, task.process.pointee.pid, running))
                if deep && running { creator = task.process }
            }
            Arch.CPU.setCurrentProcess(0)

            for _ in 0..<16 {
                guard let zombie = try? death.manager.pointee.spawnProcess(),
                      let waiter = try? death.manager.pointee.spawnProcess()
                else { Issue.record("could not create dependent processes"); return }
                holdBudget(of: zombie)
                holdBudget(of: waiter)
                death.parent.pointee.family.pushChild(zombie)
                zombie.pointee.family.parent = death.parent
                _ = death.manager.pointee.killProcess(zombie, reason: .exited(1), context: death.context)
                death.parent.pointee.family.removeChild(zombie)
                owner.pointee.family.pushChild(zombie)
                zombie.pointee.family.parent = owner
                zombies.append(zombie.pointee.pid)
                waiter.pointee.status = .blockedOnReply(owner)
                waiter.pointee.nextWaiter = owner.pointee.replyTo
                owner.pointee.replyTo = waiter
                owner.pointee.deferredReplies += 1
                waiters.append(waiter)
            }

            var snapshots: [(Int, Int, Int)] = []
            var dyingWithSpace: Set<PID> = []
            DeathWindows.inspect = {
                let liveTasks = tasks.filter { TaskRegistry.status($0.0).0 == ($0.2 ? .running : .configuring) }.count
                let liveZombies = zombies.filter { death.context.scheduler.pointee.search(in: .terminated, to: $0) != nil }.count
                let blocked = waiters.filter { $0.pointee.replyPartner == owner }.count
                snapshots.append((liveTasks, liveZombies, blocked))
                for (control, pid, running) in tasks where running {
                    guard TaskRegistry.status(control).0 == .exited else { continue }
                    if let process = ProcessStatsIndex.successor(after: pid - 1),
                       process.pointee.pid == pid,
                       process.pointee.addressSpace.vmaManager != nil {
                        dyingWithSpace.insert(pid)
                    }
                }
            }
            host_set_interrupt_window_hook { DeathWindows.inspect?() }
            PreemptionSpans.reset()
            let mask = Trace.runtimeMask
            Trace.runtimeMask = 0x3F
            TraceRing.reset()
            defer {
                host_set_interrupt_window_hook(nil); DeathWindows.inspect = nil
                TraceRing.reset(); Trace.runtimeMask = mask; PreemptionSpans.reset()
            }

            host_use_monotonic_counter(1)
            IrqOffStretch.reset()
            IrqOffStretch.open(path: 13, at: Arch.Timer.counter())
            #expect(death.manager.pointee.killProcess(owner, reason: .killed, context: death.context))
            IrqOffStretch.close(at: Arch.Timer.counter())
            print("kill-dependents host irqOffMax=\(IrqOffStretch.longest(onPath: 13)) ns windows=\(snapshots.count)")
            #expect(IrqOffStretch.longest(onPath: 13) > 0)
            host_use_monotonic_counter(0)
            IrqOffStretch.reset()
            #expect(snapshots.first?.0 == tasks.count)
            for pair in zip(snapshots, snapshots.dropFirst()) {
                #expect(pair.0.0 - pair.1.0 <= 1)
                #expect(pair.0.1 - pair.1.1 <= 1)
                #expect(pair.0.2 - pair.1.2 <= 1)
            }
            #expect(teardownSpans().count == 1)
            #expect(dyingWithSpace.count == tasks.filter { $0.2 }.count)
            #expect(owner.pointee.family.firstChild == nil)
            #expect(owner.pointee.replyTo == nil)
            #expect(owner.pointee.deferredReplies == 0)
            #expect(zombies.allSatisfy { death.context.scheduler.pointee.search(in: .terminated, to: $0) == nil })

            host_set_interrupt_window_hook(nil)
            for (control, pid, running) in tasks {
                #expect(TaskRegistry.status(control).0 == (running ? .exited : .aborted))
                if running, let corpse = death.context.scheduler.pointee.search(in: .terminated, to: pid) {
                    #expect((death.context.scheduler.pointee.reapChild(corpse)) == true)
                    death.manager.pointee.releaseProcess(corpse)
                } else if running { Issue.record("running task corpse lost") }
                TaskRegistry.release(control)
                #expect(!TaskRegistry.isLive(control))
            }
            for waiter in waiters {
                #expect(waiter.pointee.context?.pointee.x0 == IPCStatus.peerDied.rawValue)
                #expect(waiter.pointee.replyPartner == nil)
                #expect(death.manager.pointee.killProcess(waiter, reason: .killed, context: death.context))
                #expect((death.context.scheduler.pointee.reapChild(waiter)) == true)
                death.manager.pointee.releaseProcess(waiter)
            }
            #expect((death.context.scheduler.pointee.reapChild(owner)) == true)
            death.manager.pointee.releaseProcess(owner)
            #expect(ProcessStatsIndex.successor(after: death.parent.pointee.pid) == nil)
            #expect(death.parent.pointee.family.firstChild == nil)
            #expect(budgets.allSatisfy { $0.pointee.charged == 0 })
            #expect(KernelDeadlineQueue.shared.count == 0)
        }
    }

    @Test("a dying caller unlinks one server-list node per step")
    func outgoingReplyInSteps() {
        withDeath(parked: false, pages: 256) { death in
            let server = death.parent
            death.child.pointee.status = .blockedOnReply(server)
            server.pointee.replyTo = death.child
            var others: [UnsafeMutablePointer<Process>] = []
            for _ in 0..<8 {
                guard let caller = try? death.manager.pointee.spawnProcess() else {
                    Issue.record("could not make callers"); return
                }
                caller.pointee.status = .blockedOnReply(server)
                caller.pointee.nextWaiter = server.pointee.replyTo
                server.pointee.replyTo = caller
                others.append(caller)
            }
            server.pointee.deferredReplies = 8
            var linkedWindows = 0
            DeathWindows.inspect = {
                if RendezvousIPC.waiter(identity: UInt64(death.child.pointee.identity), on: server) != nil {
                    Issue.record("a dying caller still answers live lookup")
                }
                var at = server.pointee.replyTo
                while let node = at {
                    if node == death.child { linkedWindows += 1 }
                    at = node.pointee.nextWaiter
                }
            }
            host_set_interrupt_window_hook { DeathWindows.inspect?() }
            defer { host_set_interrupt_window_hook(nil); DeathWindows.inspect = nil }
            #expect(death.manager.pointee.killProcess(death.child, reason: .killed, context: death.context))
            host_set_interrupt_window_hook(nil)
            #expect(linkedWindows >= 7)
            #expect(server.pointee.deferredReplies == 7)
            for caller in others {
                #expect(caller.pointee.replyPartner == server)
                #expect(death.manager.pointee.killProcess(caller, reason: .killed, context: death.context))
                #expect((death.context.scheduler.pointee.reapChild(caller)) == true)
                death.manager.pointee.releaseProcess(caller)
            }
            #expect(server.pointee.replyTo == nil)
        }
    }

    @Test("self death clears the CPU before windows and hands the corpse to reapChild")
    func selfDeath() {
        withDeath(parked: true) { death in
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: death.child)))
            death.child.pointee.status = .running
            var windows = 0
            DeathWindows.inspect = {
                windows += 1
                #expect(Arch.CPU.getCurrentProcess() == nil)
            }
            host_set_interrupt_window_hook { DeathWindows.inspect?() }
            defer { host_set_interrupt_window_hook(nil); DeathWindows.inspect = nil }
            var frame = Arch.TrapFrame()
            death.manager.pointee.killCurrent(frame: &frame, reason: .exited(7), context: death.context)
            #expect(windows > 0)
            #expect(frame.x0 == 7)
            #expect(Arch.CPU.getCurrentProcess() == death.parent)
            #expect(death.parent.pointee.family.firstChild == nil)
            #expect(ProcessStatsIndex.successor(after: death.parent.pointee.pid) == nil)
            Arch.CPU.setCurrentProcess(0)
        }
    }

    @Test("children keep their reparent rule and a nonmember corpse is never removed", arguments: [0, 1, 2])
    func reparentInSteps(route: Int) {
        withDeath(parked: false, pages: 256) { death in
            if route > 0 {
                death.parent.pointee.family.removeChild(death.child)
                death.child.pointee.family.parent = nil
            }
            if route == 2 { death.manager.pointee.initProcess = death.child }
            var children: [UnsafeMutablePointer<Process>] = []
            for _ in 0..<8 {
                guard let child = try? death.manager.pointee.spawnProcess() else {
                    Issue.record("could not build children"); return
                }
                death.child.pointee.family.pushChild(child)
                child.pointee.family.parent = death.child
                children.insert(child, at: 0)
            }
            // The status alone does not prove ownership by the zombie queue.
            children[3].pointee.status = .terminated
            var previous = children.count
            DeathWindows.inspect = {
                let remaining = children.filter { $0.pointee.family.parent == death.child }.count
                #expect(previous - remaining <= 1)
                previous = remaining
            }
            host_set_interrupt_window_hook { DeathWindows.inspect?() }
            defer { host_set_interrupt_window_hook(nil); DeathWindows.inspect = nil }
            #expect(death.manager.pointee.killProcess(death.child, reason: .killed, context: death.context))
            host_set_interrupt_window_hook(nil)
            for child in children {
                #expect(child.pointee.family.parent == (route == 2 ? nil : death.parent))
                child.pointee.status = .new
                #expect(death.manager.pointee.killProcess(child, reason: .killed, context: death.context))
                #expect((death.context.scheduler.pointee.reapChild(child)) == true)
                death.manager.pointee.releaseProcess(child)
            }
            #expect((death.context.scheduler.pointee.reapChild(death.child)) == true)
            death.manager.pointee.releaseProcess(death.child)
            #expect(ProcessStatsIndex.successor(after: death.parent.pointee.pid) == nil)
        }
    }

    @Test("a reapChild claim survives owned deaths and the corpse is handed over once")
    func parentWaitSurvivesOwnedDeaths() {
        withDeath(parked: true, pages: 256) { death in
            var controls: [TaskControl] = []
            for _ in 0..<4 {
                Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: death.child)))
                guard let task = death.manager.pointee.createSuspendedTask(ownedBy: death.child) else {
                    Issue.record("could not create owned task"); return
                }
                TaskRegistry.retain(task.control)
                death.manager.pointee.releaseConstruction(TaskRegistry.markRunning(task.control))
                task.process.pointee.status = .blockedOnReply(death.child)
                task.process.pointee.nextWaiter = death.child.pointee.replyTo
                death.child.pointee.replyTo = task.process
                death.child.pointee.family.pushChild(task.process)
                task.process.pointee.family.parent = death.child
                controls.append(task.control)
            }
            Arch.CPU.setCurrentProcess(0)
            DeathWindows.inspect = {
                if death.parent.pointee.family.findChild(id: death.pid) != nil {
                    #expect(death.parent.pointee.metadata.pointee.waitingChildPid == death.pid)
                    if case .waiting = death.parent.pointee.status {} else {
                        Issue.record("reapChild parent resumed before the hand-off")
                    }
                }
            }
            host_set_interrupt_window_hook { DeathWindows.inspect?() }
            defer { host_set_interrupt_window_hook(nil); DeathWindows.inspect = nil }
            #expect(!death.manager.pointee.killProcess(death.child, reason: .exited(7), context: death.context))
            #expect(death.parent.pointee.metadata.pointee.waitingChildPid == nil)
            #expect(death.parent.pointee.context?.pointee.x0 == 7)
            if case .waiting = death.parent.pointee.status { Issue.record("parent was never resumed") }
            #expect(ProcessStatsIndex.successor(after: death.parent.pointee.pid) == nil)
            for control in controls {
                #expect(TaskRegistry.status(control).0 == .exited)
                TaskRegistry.release(control)
                #expect(!TaskRegistry.isLive(control))
            }
        }
    }

    // MARK: - Fixtures

    private struct Death {
        let ram    : HostRAM
        let manager: UnsafeMutablePointer<ProcessManager>
        let context: SyscallContext
        let parent : UnsafeMutablePointer<Process>
        let child  : UnsafeMutablePointer<Process>
        let pid    : PID
        let parked : Bool
    }


    /// Steps a `ProcessTeardown` over a child already marked dead the way the
    /// prologue of `killProcess` leaves it, and names what each step changed.
    private func stepThrough(_ death: Death) -> [[String]] {
        _ = death.manager.pointee.beginDeath(death.child, reason: .exited(7), context: death.context)

        var teardown = ProcessTeardown(
            process: death.child,
            parent : death.parked ? death.parent : nil,
            context: death.context
        )

        let asid = death.child.pointee.addressSpace.asid
        var last = DeathObservation(of: death, asid: asid, freed: false)
        var log  : [[String]] = []

        while true {
            let progress = teardown.step()
            let freed    = death.parked && progress == .done
            let next     = DeathObservation(of: death, asid: asid, freed: freed)

            log.append(next.changed(from: last))
            last = next

            if progress == .done { return log }
        }
    }


    /// What a window between two steps would find. The corpse's own facts are
    /// `nil` once its block is freed.
    private struct DeathObservation {
        var space   : Observation?
        var deadline: Bool?
        var caps    : Int?
        var metadata: Bool?
        var inTree  : Bool
        var zombie  : Bool
        var claim   : Bool
        var status  : UInt64?
        var woken   : Bool

        init(of death: Death, asid: ASID, freed: Bool) {
            let child  = death.child
            let parent = death.parent

            if freed {
                space    = nil
                deadline = nil
                caps     = nil
                metadata = nil

            } else {
                space    = Observation(of: child, asid: asid)
                deadline = child.pointee.kernelDeadlineKind != .none
                metadata = child.pointee.metadata != nil
                caps     = child.pointee.metadata.map { table in
                    (0..<table.pointee.capsTable.caps.count).filter {
                        table.pointee.capsTable.caps[$0] != nil
                    }.count
                }
            }

            inTree = parent.pointee.family.findChild(id: death.pid) != nil
            zombie = death.context.scheduler.pointee.search(in: .terminated, to: death.pid) != nil
            claim  = parent.pointee.metadata.pointee.waitingChildPid != nil
            status = parent.pointee.context?.pointee.x0

            if case .waiting = parent.pointee.status { woken = false } else { woken = true }
        }

        func changed(from previous: DeathObservation) -> [String] {
            var names: [String] = []

            if let space, let before = previous.space {
                names += space.changed(from: before)
            }

            if space == nil, previous.space != nil { names.append("freed") }

            if let deadline, deadline != previous.deadline { names.append("deadline") }
            if let caps, caps != previous.caps { names.append("caps") }
            if let metadata, metadata != previous.metadata { names.append("metadata") }

            if inTree != previous.inTree { names.append("unlinked") }
            if zombie != previous.zombie { names.append("zombie") }
            if claim  != previous.claim  { names.append("claim") }
            if status != previous.status { names.append("status") }
            if woken  != previous.woken  { names.append("woken") }

            return names
        }
    }


    /// A parent and a child it spawned, the child holding one faulted page and
    /// two capabilities. `parked` puts the parent in `reapChild` on the child.
    private func withDeath(parked: Bool, pages: Int = 192, _ body: (Death) -> Void) {
        withProcessManager(pages: pages) { ram, heap, manager in
            TaskRegistry.resetForTesting()
            defer { TaskRegistry.resetForTesting() }

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            guard let parent  = try? manager.pointee.spawnProcess(),
                  let child   = try? manager.pointee.spawnProcess(),
                  let vma     = child.pointee.addressSpace.vmaManager,
                  let address = try? vma.pointee.mmapAnonymous(
                    size       : 4096,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not build the family")
                return
            }

            manager.pointee.initProcess = parent
            defer { manager.pointee.initProcess = nil }

            parent.pointee.family.pushChild(child)
            child.pointee.family.parent = parent

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: child)))
            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .write
            ) == .handled)

            // Parked the way `reapChild` parks it: blocked, then the claim.
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))
            #expect((try? scheduler.pointee.block(parent.pointee.pid)) != nil)
            Arch.CPU.setCurrentProcess(0)

            if parked {
                parent.pointee.metadata.pointee.waitingChildPid = child.pointee.pid
            }

            for slot: UInt32 in [3, 9] {
                let placed = child.pointee.metadata.pointee.capsTable.install(
                    at: slot,
                    Capability(target: .power, badge: 0, rights: [.spawn])
                )
                #expect(placed.installed && placed.displaced == nil)
            }

            let armed = KernelDeadlineQueue.shared.arm(child, kind: .ipc, deadline: 1_000_000)
            #expect(armed)

            mmu_trace_reset(nil)

            body(Death(
                ram    : ram,
                manager: manager,
                context: context,
                parent : parent,
                child  : child,
                pid    : child.pointee.pid,
                parked : parked
            ))
        }
    }
}
}

private enum DeathWindows {
    static var inspect: (() -> Void)?
}
