//
//  TaskTerminateSyscallTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

/// `taskTerminate` through the syscall handler, with the job capability held by
/// someone the kill may reach. A job can be delegated to a task its target owns,
/// at any depth, so the caller can die inside its own syscall without being the
/// target. It must then leave the way `exit` does: off the CPU before any
/// window, and back to user mode only as somebody else.
extension KernelPolicyTestRoot {
@Suite("Job termination reaching the caller", .serialized)
struct TaskTerminateSyscallTests {

    /// What the bystander's saved `x0` reads, so a frame that became its context
    /// is told apart from one the syscall wrote a result into.
    private static let bystanderX0: UInt64 = 0xB0B

    @Test("a running descendant that terminates its owner through a job leaves like exit",
          arguments: [(0, false), (1, false), (1, true), (2, false), (2, true)])
    func descendantKillsOwner(depth: Int, ownersParked: Bool) {
        withJobs { jobs in
            let snapshot = jobs.snapshot()
            let chain = jobs.chain(depth: depth)
            guard chain.count == depth + 1 else { return }
            let caller = chain[depth]

            // The owners above the caller wait in reapChild on their child, or
            // sit ready; either way none of them is the running one.
            for index in 0..<depth {
                let owner = chain[index].process
                if ownersParked {
                    Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: owner)))
                    owner.pointee.metadata.pointee.waitingChildPid = chain[index + 1].process.pointee.pid
                    #expect((try? jobs.context.scheduler.pointee.block(owner.pointee.pid)) != nil)
                } else {
                    #expect((try? jobs.context.scheduler.pointee.addTask(owner)) != nil)
                }
            }
            caller.process.pointee.status = .running
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: caller.process)))

            guard let job = jobs.delegate(chain[0].control, to: caller.process) else { return }

            // Every window after the caller's death is published must find it gone.
            var windows = 0
            var stale   = 0
            JobWindows.inspect = {
                guard TaskRegistry.status(caller.control).0 == .exited else { return }
                windows += 1
                if Arch.CPU.getCurrentProcess() != nil { stale += 1 }
            }
            host_set_interrupt_window_hook { JobWindows.inspect?() }
            defer { host_set_interrupt_window_hook(nil); JobWindows.inspect = nil }

            var frame = Arch.TrapFrame()
            frame.x0 = UInt64(job)
            jobs.handler.pointee.handle(type: .taskTerminate, frame: &frame)
            host_set_interrupt_window_hook(nil)

            #expect(windows > 0)
            #expect(stale == 0)
            #expect(Arch.CPU.getCurrentProcess() == jobs.bystander)
            #expect(frame.x0 == Self.bystanderX0)
            if case .running = jobs.bystander.pointee.status {} else {
                Issue.record("the bystander was not scheduled in")
            }

            jobs.reapRoot(of: chain)
            jobs.release(chain)
            jobs.expectBalanced(since: snapshot)
        }
    }


    @Test("a job killed around a blocked descendant returns to its caller",
          arguments: [1, 2])
    func blockedDescendantKeepsCaller(depth: Int) {
        withJobs { jobs in
            let snapshot = jobs.snapshot()
            let chain = jobs.chain(depth: depth)
            guard chain.count == depth + 1 else { return }

            // The deepest descendant is parked; the job is used by an outsider.
            let blocked = chain[depth].process
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: blocked)))
            #expect((try? jobs.context.scheduler.pointee.block(blocked.pointee.pid)) != nil)
            for link in chain.dropLast() {
                #expect((try? jobs.context.scheduler.pointee.addTask(link.process)) != nil)
            }

            let caller = jobs.owner
            caller.pointee.status = .running
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: caller)))
            guard let job = jobs.delegate(chain[0].control, to: caller) else { return }

            var frame = Arch.TrapFrame()
            frame.x0 = UInt64(job)
            jobs.handler.pointee.handle(type: .taskTerminate, frame: &frame)

            #expect(frame.x0 == TaskResult.ok.rawValue)
            #expect(Arch.CPU.getCurrentProcess() == caller)
            if case .ready = jobs.bystander.pointee.status {} else {
                Issue.record("the bystander was scheduled although the caller lives")
            }

            jobs.reapRoot(of: chain)

            if case .failure = jobs.ipc.pointee.releaseCapability(job, of: caller) {
                Issue.record("the outsider's job could not be dropped")
            }
            jobs.release(chain)
            jobs.expectBalanced(since: snapshot)
        }
    }


    // MARK: - Fixture

    private struct Link {
        let control: TaskControl
        let process: UnsafeMutablePointer<Process>
        let pid    : PID
    }

    private struct Jobs {
        let ram      : HostRAM
        let heap     : UnsafeMutablePointer<KernelHeap>
        let manager  : UnsafeMutablePointer<ProcessManager>
        let ipc      : UnsafeMutablePointer<KernelIPC>
        let context  : SyscallContext
        let handler  : UnsafeMutablePointer<SyscallHandler>
        let owner    : UnsafeMutablePointer<Process>
        let bystander: UnsafeMutablePointer<Process>

        /// A started task owned by `owner`, then one owned by it, `depth` times.
        /// Each is its creator's child, as `taskCreate` links it.
        func chain(depth: Int) -> [Link] {
            var links: [Link] = []
            var creator = owner
            for _ in 0...depth {
                Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: creator)))
                guard let task = manager.pointee.createSuspendedTask(ownedBy: creator) else {
                    Issue.record("could not create an owned task")
                    break
                }
                TaskRegistry.retain(task.control)
                manager.pointee.releaseConstruction(TaskRegistry.markRunning(task.control))
                creator.pointee.family.pushChild(task.process)
                task.process.pointee.family.parent = creator
                links.append(Link(control: task.control, process: task.process, pid: task.process.pointee.pid))
                creator = task.process
            }
            Arch.CPU.setCurrentProcess(0)
            return links
        }

        /// Install a job on `control` in `holder`'s table, retained the way a grant
        /// retains it, so the holder's death gives the reference back.
        func delegate(_ control: TaskControl, to holder: UnsafeMutablePointer<Process>) -> UInt32? {
            let job = Capability(target: .job(control), badge: 0, rights: [.taskTerminate, .taskStatus])
            guard let handle = holder.pointee.metadata.pointee.capsTable.install(job) else {
                Issue.record("no slot for the job")
                return nil
            }
            ipc.pointee.retain(job)
            return handle
        }

        /// Every task exited killed. A dying owner takes its child's corpse, by
        /// hand-off or by collecting the zombie, so only the root's is left.
        func reapRoot(of chain: [Link]) {
            for link in chain {
                #expect(TaskRegistry.status(link.control) == (.exited, 0))
            }
            for link in chain.dropFirst() {
                #expect(context.scheduler.pointee.search(in: .terminated, to: link.pid) == nil)
            }
            guard let root = context.scheduler.pointee.search(in: .terminated, to: chain[0].pid) else {
                Issue.record("the root corpse was lost")
                return
            }
            if case .killed? = root.pointee.metadata?.pointee.exitReason {} else {
                Issue.record("the root did not die killed")
            }
            #expect((context.scheduler.pointee.reapChild(root)) == true)
            manager.pointee.releaseProcess(root)
        }

        func release(_ chain: [Link]) {
            for link in chain {
                TaskRegistry.release(link.control)
                #expect(!TaskRegistry.isLive(link.control))
            }
        }

        struct Snapshot {
            let pages    : UInt64
            let live     : UInt64
            let processes: Int
        }

        func snapshot() -> Snapshot {
            Snapshot(
                pages    : ram.ppm.pointee.allocatedPages,
                live     : heap.pointee.metricsLiveBytes,
                processes: Self.indexed()
            )
        }

        func expectBalanced(since before: Snapshot) {
            #expect(ram.ppm.pointee.allocatedPages == before.pages)
            #expect(heap.pointee.metricsLiveBytes == before.live)
            #expect(Self.indexed() == before.processes)
            #expect(owner.pointee.family.firstChild == nil)
            #expect(KernelDeadlineQueue.shared.count == 0)
        }

        private static func indexed() -> Int {
            var count = 0
            var pid: PID = 0
            while let process = ProcessStatsIndex.successor(after: pid) {
                count += 1
                pid = process.pointee.pid
            }
            return count
        }
    }


    private func withJobs(_ body: (Jobs) -> Void) {
        withProcessManager(pages: 384) { ram, heap, manager in
            TaskRegistry.resetForTesting()
            defer { TaskRegistry.resetForTesting() }

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let handler = UnsafeMutablePointer<SyscallHandler>.allocate(capacity: 1)
            handler.initialize(to: SyscallHandler(
                processManager: manager, scheduler: scheduler, ipc: ipc, ppm: ram.ppm
            ))
            defer { handler.deinitialize(count: 1); handler.deallocate() }

            guard let owner     = try? manager.pointee.spawnProcess(),
                  let bystander = try? manager.pointee.spawnProcess()
            else {
                Issue.record("could not build the owner and the bystander")
                return
            }
            bystander.pointee.context?.pointee.x0 = Self.bystanderX0
            #expect((try? scheduler.pointee.addTask(bystander)) != nil)

            body(Jobs(
                ram      : ram,
                heap     : heap,
                manager  : manager,
                ipc      : ipc,
                context  : SyscallContext(
                    processManager: manager,
                    scheduler     : scheduler,
                    ipc           : ipc,
                    ppm           : ram.ppm
                ),
                handler  : handler,
                owner    : owner,
                bystander: bystander
            ))
        }
    }
}
}

private enum JobWindows {
    static var inspect: (() -> Void)?
}
