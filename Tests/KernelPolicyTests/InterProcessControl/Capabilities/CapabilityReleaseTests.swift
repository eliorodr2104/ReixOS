//
//  CapabilityReleaseTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport

/// `CapabilityRelease`, the stepped release a death runs under the teardown
/// region. What a release does to each kind of target is covered where it
/// always was; this suite owns the steps and the windows between them.
///
/// `.power` targets carry no reference count, so a zeroed `KernelIPC` can
/// release them without touching anything a fixture would have to build.
extension KernelPolicyTestRoot {
@Suite("Capability release in steps", .serialized)
struct CapabilityReleaseTests {

    /// On the host the budget is zero, so a window follows every step that
    /// leaves work behind: one fewer than the slots held.
    @Test("every held slot is released, a window between two of them, none for the gaps")
    func windowsBetweenHeldSlots() {
        withCapabilities(at: [2, 5, 9, 31]) { ipc, metadata in
            _ = Preemption.run(
                AddressSpaceTeardown.self,
                CapabilityRelease(ipc: ipc, metadata: metadata)
            )

            #expect(PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints == 3)
            #expect(heldSlots(metadata).isEmpty)
        }
    }


    @Test("an empty table takes one step and opens nothing")
    func emptyTable() {
        withCapabilities(at: []) { ipc, metadata in
            var release = CapabilityRelease(ipc: ipc, metadata: metadata)
            #expect(release.step() == .done)

            #expect(PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints == 0)
        }
    }


    @Test("one slot per step, and the step that empties the last slot is the last")
    func oneSlotPerStep() {
        withCapabilities(at: [0, 1, 31]) { ipc, metadata in
            var release = CapabilityRelease(ipc: ipc, metadata: metadata)

            #expect(release.step() == .more)
            #expect(heldSlots(metadata) == [1, 31])

            #expect(release.step() == .more)
            #expect(heldSlots(metadata) == [31])

            // Slot 31 is the table's last, so its step finishes the run.
            #expect(release.step() == .done)
            #expect(heldSlots(metadata).isEmpty)
        }
    }


    @Test("a held slot followed only by gaps ends the run on the gaps' step")
    func trailingGaps() {
        withCapabilities(at: [3]) { ipc, metadata in
            var release = CapabilityRelease(ipc: ipc, metadata: metadata)

            #expect(release.step() == .more)
            #expect(heldSlots(metadata).isEmpty)
            #expect(release.step() == .done)
        }
    }


    /// The same death twice, once holding four more capabilities: the
    /// difference in teardown windows is the four slots, whatever the address
    /// space contributed to both.
    @Test("a death and an abort release the table under the teardown region",
          arguments: [false, true])
    func deathPathsAreStepped(abort: Bool) {
        let without = teardownWindows(abort: abort, extraSlots: [])
        let with    = teardownWindows(abort: abort, extraSlots: [10, 11, 12, 13])

        #expect(with - without == 4)
    }


    // MARK: - Fixtures

    private func teardownWindows(abort: Bool, extraSlots: [UInt32]) -> UInt64 {
        var windows: UInt64 = 0

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

            guard let parent = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the parent")
                return
            }
            manager.pointee.initProcess = parent
            defer { manager.pointee.initProcess = nil }

            let victim: UnsafeMutablePointer<Process>
            var control: TaskControl? = nil

            if abort {
                guard let task = manager.pointee.createSuspendedTask(ownedBy: parent) else {
                    Issue.record("could not create the task")
                    return
                }
                victim  = task.process
                control = task.control

            } else {
                guard let child = try? manager.pointee.spawnProcess() else {
                    Issue.record("could not spawn the child")
                    return
                }
                parent.pointee.family.pushChild(child)
                child.pointee.family.parent = parent
                victim = child
            }

            for slot in extraSlots {
                let placed = victim.pointee.metadata.pointee.capsTable.install(
                    at: slot,
                    Capability(target: .power, badge: 0, rights: [.spawn])
                )
                #expect(placed.installed && placed.displaced == nil)
            }

            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            if let control {
                #expect(manager.pointee.abortTask(control, context: context) == .ok)
            } else {
                _ = manager.pointee.killProcess(victim, reason: .exited(0), context: context)
            }

            windows = PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints
        }

        return windows
    }


    private func withCapabilities(
        at slots: [Int],
        _ body  : (UnsafeMutablePointer<KernelIPC>, UnsafeMutablePointer<ProcessMetadata>) -> Void
    ) {
        withKernelTestGlobals {
            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            let ipc = allocateZeroedStorage(KernelIPC.self)
            defer { UnsafeMutableRawPointer(ipc).deallocate() }

            let metadata = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
            metadata.initialize(to: ProcessMetadata())
            defer { metadata.deinitialize(count: 1); metadata.deallocate() }

            for slot in slots {
                let placed = metadata.pointee.capsTable.install(
                    at: UInt32(slot),
                    Capability(target: .power, badge: 0, rights: [.spawn])
                )
                #expect(placed.installed && placed.displaced == nil)
            }

            body(ipc, metadata)
        }
    }


    private func heldSlots(_ metadata: UnsafeMutablePointer<ProcessMetadata>) -> [Int] {
        (0..<metadata.pointee.capsTable.caps.count).filter {
            metadata.pointee.capsTable.caps[$0] != nil
        }
    }
}
}
