//
//  ProcessManager+TasksTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

extension KernelPolicyTestRoot {

/// The lifetime of a task's construction object through the process manager:
/// what `taskCreate` charges, every refusal that has to leave nothing behind,
/// every way out of `configuring` giving the object and its frame back, and
/// the configuring operations refusing every other state.
@Suite("Task construction lifetime", .serialized)
struct ProcessManagerTasksTests {

    private static let page  = UserSpaceLayout.pageSize
    private static let text  = UserSpaceLayout.elfBaseTypical
    private static let stack = UserSpaceLayout.stackTop - UserSpaceLayout.pageSize

    /// The slab bucket a construction object lands in.
    private static let constructionBucket: UInt64 = 1024


    // MARK: - Create and start

    @Test("create charges the owner one frame and a budget reference, and start gives both back")
    func createChargesStartRefunds() {
        withTasks { fixture in
            let budget = fixture.budget
            let charged    = budget.pointee.charged
            let references = budget.pointee.references

            guard let task = fixture.create() else { return }
            #expect(budget.pointee.charged == charged + 1)
            #expect(budget.pointee.references == references + 1)
            #expect(TaskRegistry.configuring(task.control)?.construction.pointee.budget == budget)

            Self.makeReady(task.control, fixture)
            let live = fixture.heap.pointee.metricsLiveBytes

            let started = fixture.manager.pointee.startTask(task.control, context: fixture.context)
            #expect(started.result == .ok)
            #expect(started.pid == task.process.pointee.pid)
            #expect(budget.pointee.charged == charged)
            #expect(budget.pointee.references == references)
            #expect(live - fixture.heap.pointee.metricsLiveBytes == Self.constructionBucket)
            #expect(TaskRegistry.configuring(task.control) == nil)
            #expect(TaskRegistry.runningProcess(task.control) == task.process)

            Self.reap(task.process, fixture, kill: true)
        }
    }


    @Test("a start that is not ready keeps the construction and the charge")
    func unreadyStartKeepsConstruction() {
        withTasks { fixture in
            guard let task = fixture.create() else { return }
            let charged = fixture.budget.pointee.charged

            #expect(fixture.manager.pointee.startTask(task.control, context: fixture.context).result == .invalidState)
            #expect(fixture.budget.pointee.charged == charged)
            #expect(TaskRegistry.configuring(task.control) != nil)

            #expect(fixture.manager.pointee.abortTask(task.control, context: fixture.context) == .ok)
        }
    }


    // MARK: - Refusals at create

    @Test("a create the budget refuses takes no slot, no charge, no frame and no heap")
    func budgetExhaustedAtCreate() {
        withTasks { fixture in
            let budget = fixture.budget
            budget.pointee.limit = budget.pointee.charged
            let snapshot = fixture.snapshot()

            #expect(fixture.create() == nil)
            fixture.expectUnchanged(since: snapshot)

            // One frame of headroom is exactly enough.
            budget.pointee.limit = budget.pointee.charged + 1
            guard let task = fixture.create() else {
                Issue.record("a create with one frame of headroom was refused")
                return
            }
            #expect(budget.pointee.charged == budget.pointee.limit)
            #expect(fixture.manager.pointee.abortTask(task.control, context: fixture.context) == .ok)
        }
    }


    @Test("a create the heap refuses at the construction leaves nothing behind")
    func heapRefusesConstruction() {
        withTasks { fixture in
            let snapshot = fixture.snapshot()

            KernelHeap.failAllocationsAfter = 0
            defer { KernelHeap.failAllocationsAfter = nil }
            #expect(fixture.create() == nil)
            KernelHeap.failAllocationsAfter = nil

            fixture.expectUnchanged(since: snapshot)
        }
    }


    @Test("a create whose spawn fails gives the construction back")
    func spawnFailureReleasesConstruction() {
        withTasks { fixture in
            let snapshot = fixture.snapshot()

            // The construction is served, the child's metadata is not.
            KernelHeap.failAllocationsAfter = 1
            defer { KernelHeap.failAllocationsAfter = nil }
            #expect(fixture.create() == nil)
            #expect(KernelHeap.failAllocationsAfter == 0)
            KernelHeap.failAllocationsAfter = nil

            fixture.expectUnchanged(since: snapshot)
        }
    }


    @Test("a create the full registry refuses unwinds the process and the construction")
    func fullRegistryUnwinds() {
        withTasks(pages: 640) { fixture in
            var tasks: [TaskControl] = []
            for _ in 0..<TaskRegistry.capacity {
                guard let task = fixture.create() else {
                    Issue.record("the registry filled before its capacity")
                    return
                }
                tasks.append(task.control)
            }

            let snapshot = fixture.snapshot()
            #expect(fixture.create() == nil)
            fixture.expectUnchanged(since: snapshot)

            for control in tasks {
                #expect(fixture.manager.pointee.abortTask(control, context: fixture.context) == .ok)
            }
        }
    }


    // MARK: - Teardown orders

    @Test("an abort before start gives the construction, the frame and the address space back")
    func abortBeforeStart() {
        withTasks { fixture in
            let snapshot = fixture.snapshot()

            guard let task = fixture.create() else { return }
            #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: Self.text, pages: 1) == .ok)

            #expect(fixture.manager.pointee.abortTask(task.control, context: fixture.context) == .ok)
            fixture.expectUnchanged(since: snapshot)

            // No capability held it, so the record went with the process.
            #expect(!TaskRegistry.isLive(task.control))
            #expect(fixture.manager.pointee.abortTask(task.control, context: fixture.context) == .invalidState)
        }
    }


    @Test("an owner that dies while configuring gives every construction back")
    func ownerDiesWhileConfiguring() {
        withTasks { fixture in
            let budget = fixture.budget
            let charged    = budget.pointee.charged
            let references = budget.pointee.references

            guard let held    = fixture.create(),
                  let unheld  = fixture.create(),
                  let running = fixture.create()
            else { return }
            TaskRegistry.retain(held.control)
            Self.makeReady(running.control, fixture)
            #expect(fixture.manager.pointee.startTask(running.control, context: fixture.context).result == .ok)
            #expect(budget.pointee.charged == charged + 2)

            fixture.kill(fixture.owner, reason: .killed)

            // The owner's own address space went too, so nothing is left charged.
            #expect(budget.pointee.charged == 0)
            #expect(budget.pointee.references == references)
            #expect(TaskRegistry.status(held.control).0 == .aborted)
            #expect(!TaskRegistry.isLive(unheld.control))
            #expect(TaskRegistry.status(running.control).0 == .exited)

            Self.reap(running.process, fixture)
            Self.reap(fixture.owner, fixture)
        }
    }


    @Test("a task killed before it starts gives the construction back on its exit")
    func killedBeforeStart() {
        withTasks { fixture in
            let charged = fixture.budget.pointee.charged
            let live    = fixture.heap.pointee.metricsLiveBytes

            guard let task = fixture.create() else { return }
            let afterCreate = fixture.heap.pointee.metricsLiveBytes
            #expect(afterCreate > live)

            fixture.kill(task.process, reason: .killed)
            #expect(fixture.budget.pointee.charged == charged)
            #expect(TaskRegistry.status(task.control).0 == .exited)
            #expect(TaskRegistry.configuring(task.control) == nil)

            Self.reap(task.process, fixture)
            #expect(fixture.heap.pointee.metricsLiveBytes == live)
        }
    }


    @Test("a process that exits while its capability lives keeps the status until the last release")
    func exitWhileCapabilityLives() {
        withTasks { fixture in
            guard let task = fixture.create() else { return }
            TaskRegistry.retain(task.control)
            Self.makeReady(task.control, fixture)
            #expect(fixture.manager.pointee.startTask(task.control, context: fixture.context).result == .ok)

            fixture.kill(task.process, reason: .exited(5))
            Self.reap(task.process, fixture)

            #expect(TaskRegistry.isLive(task.control))
            #expect(TaskRegistry.status(task.control) == (.exited, 5))

            TaskRegistry.release(task.control)
            #expect(!TaskRegistry.isLive(task.control))
        }
    }


    @Test("a capability dropped while the task runs leaves the record to the process")
    func capabilityDroppedWhileRunning() {
        withTasks { fixture in
            guard let task = fixture.create() else { return }
            TaskRegistry.retain(task.control)
            Self.makeReady(task.control, fixture)
            #expect(fixture.manager.pointee.startTask(task.control, context: fixture.context).result == .ok)

            TaskRegistry.release(task.control)
            #expect(TaskRegistry.status(task.control).0 == .running)

            fixture.kill(task.process, reason: .exited(0))
            #expect(TaskRegistry.isLive(task.control))
            Self.reap(task.process, fixture)
            #expect(!TaskRegistry.isLive(task.control))
        }
    }


    @Test("a seal the construction disagrees with tears the child down as an abort does")
    func sealDisagreementAborts() {
        withTasks { fixture in
            let snapshot = fixture.snapshot()

            guard let task = fixture.create() else { return }
            TaskRegistry.retain(task.control)
            #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: Self.text, pages: 1) == .ok)

            // The VMA accepts the seal while the construction forgot the region,
            // the disagreement `sealTaskRegion` says cannot happen.
            TaskRegistry.configuring(task.control)?.construction.pointee.regionCount = 0
            #expect(fixture.manager.pointee.sealTaskRegion(task.control, at: Self.text, pages: 1, permissions: [.read], context: fixture.context) == .invalidState)

            #expect(TaskRegistry.status(task.control).0 == .aborted)

            // Frames, heap, budget and the child's record all went with it.
            TaskRegistry.release(task.control)
            fixture.expectUnchanged(since: snapshot)
        }
    }


    // MARK: - States and regions

    @Test("the configuring operations refuse a started, an aborted and a stale task")
    func configuringOperationsRefuseOtherStates() {
        withTasks { fixture in
            UserMemory.validationOverride = { _, _, _ in true }
            let source = VirtualAddress(UInt(bitPattern: fixture.scratch))

            guard let started = fixture.create() else { return }
            #expect(fixture.manager.pointee.terminateTask(started.control, context: fixture.context) == .invalidState)
            Self.makeReady(started.control, fixture)
            #expect(fixture.manager.pointee.startTask(started.control, context: fixture.context).result == .ok)

            // A held capability keeps the aborted record from being collected.
            guard let aborted = fixture.create() else { return }
            TaskRegistry.retain(aborted.control)
            #expect(fixture.manager.pointee.abortTask(aborted.control, context: fixture.context) == .ok)

            guard let replaced = fixture.create() else { return }
            #expect(fixture.manager.pointee.abortTask(replaced.control, context: fixture.context) == .ok)
            guard let reuse = fixture.create() else { return }
            #expect(reuse.control.slot == replaced.control.slot)

            for control in [started.control, aborted.control, replaced.control] {
                let manager = fixture.manager
                #expect(manager.pointee.mapTaskAnonymous(control, at: Self.text + 8 * Self.page, pages: 1) == .invalidState)
                #expect(manager.pointee.writeTask(control, at: Self.text, from: source, count: 1) == .invalidRange)
                #expect(manager.pointee.sealTaskRegion(control, at: Self.text, pages: 1, permissions: [.read], context: fixture.context) == .invalidState)
                #expect(manager.pointee.setTaskContext(control, entry: Self.text, stack: UserSpaceLayout.stackTop, programBreak: Self.text + Self.page) == .invalidRange)
                #expect(manager.pointee.startTask(control, context: fixture.context).result == .invalidState)
                #expect(manager.pointee.abortTask(control, context: fixture.context) == .invalidState)
            }

            #expect(fixture.manager.pointee.writeTask(reuse.control, at: Self.text, from: source, count: 1) == .invalidRange)
            #expect(fixture.manager.pointee.abortTask(reuse.control, context: fixture.context) == .ok)
            Self.reap(started.process, fixture, kill: true)
        }
    }


    @Test("a task holds the ABI's region count and the mapping past it is rolled back")
    func regionLimitRollsBack() {
        withTasks(pages: 400) { fixture in
            guard let task = fixture.create() else { return }
            let limit = Int(TaskABI.maximumRegions)

            // A gap between mappings keeps the VMA list from merging them.
            for index in 0..<limit {
                let address = Self.text + UInt64(2 * index) * Self.page
                #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: address, pages: 1) == .ok)
            }

            let pages = fixture.ram.ppm.pointee.allocatedPages
            let past  = Self.text + UInt64(2 * limit) * Self.page
            #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: past, pages: 1) == .full)
            #expect(task.process.pointee.addressSpace.vmaManager?.pointee.vmaList.search(at: past) == nil)
            #expect(fixture.ram.ppm.pointee.allocatedPages == pages)
            #expect(TaskRegistry.configuring(task.control)?.construction.pointee.regionCount == UInt8(limit))

            #expect(fixture.manager.pointee.abortTask(task.control, context: fixture.context) == .ok)
        }
    }


    @Test("an overlapping mapping is refused and takes no region")
    func overlapTakesNoRegion() {
        withTasks { fixture in
            guard let task = fixture.create() else { return }

            #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: Self.text, pages: 2) == .ok)
            #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: Self.text, pages: 1) == .invalidRange)
            #expect(fixture.manager.pointee.mapTaskAnonymous(task.control, at: Self.text + Self.page, pages: 2) == .invalidRange)
            #expect(TaskRegistry.configuring(task.control)?.construction.pointee.regionCount == 1)

            #expect(fixture.manager.pointee.abortTask(task.control, context: fixture.context) == .ok)
        }
    }


    // MARK: - Fixtures

    private struct Fixture {
        let ram      : HostRAM
        let heap     : UnsafeMutablePointer<KernelHeap>
        let manager  : UnsafeMutablePointer<ProcessManager>
        let scheduler: UnsafeMutablePointer<KernelScheduler>
        let context  : SyscallContext
        let owner    : UnsafeMutablePointer<Process>
        let scratch  : UnsafeMutablePointer<UInt8>

        var budget: UnsafeMutablePointer<FrameBudget> { owner.pointee.metadata.pointee.budget }

        func create() -> (control: TaskControl, process: UnsafeMutablePointer<Process>)? {
            manager.pointee.createSuspendedTask(ownedBy: owner)
        }

        /// Kill `process`, once the owner walk its teardown makes is checked.
        func kill(_ process: UnsafeMutablePointer<Process>, reason: ExitReason) {
            guard teardownWalkIsOwned(by: process.pointee.identity) else { return }
            _ = manager.pointee.killProcess(process, reason: reason, context: context)
        }

        struct Snapshot {
            let pages     : UInt64
            let live      : UInt64
            let charged   : UInt32
            let references: UInt32
            let owned     : [TaskControl?]
        }

        func snapshot() -> Snapshot {
            Snapshot(
                pages     : ram.ppm.pointee.allocatedPages,
                live      : heap.pointee.metricsLiveBytes,
                charged   : budget.pointee.charged,
                references: budget.pointee.references,
                owned     : (0..<TaskRegistry.capacity).map {
                    TaskRegistry.control(at: $0, ownedBy: owner.pointee.identity)
                }
            )
        }

        func expectUnchanged(since before: Snapshot) {
            let after = snapshot()
            #expect(after.pages == before.pages)
            #expect(after.live == before.live)
            #expect(after.charged == before.charged)
            #expect(after.references == before.references)
            #expect(after.owned == before.owned)
        }
    }


    private func withTasks(pages: Int = 256, _ body: (Fixture) -> Void) {
        withProcessManager(pages: pages) { ram, heap, manager in
            TaskRegistry.resetForTesting()
            defer {
                UserMemory.validationOverride = nil
                KernelHeap.failAllocationsAfter = nil
                TaskRegistry.resetForTesting()
            }

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
            defer { scratch.deallocate() }

            guard let owner = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create the task owner")
                return
            }

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            body(Fixture(
                ram      : ram,
                heap     : heap,
                manager  : manager,
                scheduler: scheduler,
                context  : context,
                owner    : owner,
                scratch  : scratch
            ))
        }
    }


    /// Map, seal and point a task at one text page and one stack page.
    private static func makeReady(_ control: TaskControl, _ fixture: Fixture) {
        let manager = fixture.manager
        #expect(manager.pointee.mapTaskAnonymous(control, at: text, pages: 1) == .ok)
        #expect(manager.pointee.mapTaskAnonymous(control, at: stack, pages: 1) == .ok)
        #expect(manager.pointee.sealTaskRegion(control, at: text, pages: 1, permissions: [.read, .execute], context: fixture.context) == .ok)
        #expect(manager.pointee.sealTaskRegion(control, at: stack, pages: 1, permissions: [.read, .write], context: fixture.context) == .ok)
        #expect(manager.pointee.setTaskContext(
            control,
            entry       : text,
            stack       : UserSpaceLayout.stackTop,
            programBreak: text + page
        ) == .ok)
    }


    /// Collect a dead process the way its parent would, killing it first when asked.
    private static func reap(
        _ process: UnsafeMutablePointer<Process>,
        _ fixture: Fixture,
        kill     : Bool = false
    ) {
        if kill {
            fixture.kill(process, reason: .killed)
        }
        let reaped = fixture.scheduler.pointee.reapChild(process)
        #expect(reaped)
        fixture.manager.pointee.releaseProcess(process)
    }
}
}
