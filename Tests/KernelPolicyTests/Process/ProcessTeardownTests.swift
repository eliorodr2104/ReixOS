//
//  ProcessTeardownTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// `ProcessTeardown`, a death after its prologue as one operation. The suite
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

            #expect(log == [
                ["regions"], [], [], ["manager"], ["trapFrame"], ["invalidated"],
                ["deadline"],
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

            #expect(log == [
                ["regions"], [], [], ["manager"], ["trapFrame"], ["invalidated"],
                ["deadline"],
                ["caps"], ["caps"], [],
                ["unlinked", "claim", "status"],
                ["metadata"],
                ["freed", "woken"]
            ])

            #expect(death.parent.pointee.context?.pointee.x0 == 7)
        }
    }


    /// On the host the budget is zero, so a window follows every step that
    /// leaves work behind: eleven steps to the list, thirteen to the parent.
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

            let windows: UInt64 = parked ? 12 : 10

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
        death.child.pointee.status                       = .terminated
        death.child.pointee.metadata?.pointee.exitReason = .exited(7)

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
    private func withDeath(parked: Bool, _ body: (Death) -> Void) {
        withProcessManager(pages: 192) { ram, heap, manager in
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
