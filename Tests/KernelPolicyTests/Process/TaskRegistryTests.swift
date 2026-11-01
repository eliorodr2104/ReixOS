//
//  TaskRegistryTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

extension KernelPolicyTestRoot {

/// The registry on its own: slots, generations, ownership, the lifecycle and
/// the hand-back of the construction object, and when a record is collected.
///
/// The registry never dereferences the process or construction it is given,
/// so these run on placeholder pointers and need no process manager.
@Suite("Task registry", .serialized)
struct TaskRegistryTests {

    private static let owner   : Identity = 7
    private static let stranger: Identity = 8

    private static let process = UnsafeMutablePointer<Process>(bitPattern: 0x1000)!

    private static func construction(_ tag: UInt) -> UnsafeMutablePointer<TaskConstruction> {
        UnsafeMutablePointer<TaskConstruction>(bitPattern: 0x10_0000 + tag * 0x1000)!
    }


    // MARK: - Slots and generations

    @Test("every slot can be taken once and the one past the last is refused")
    func capacity() {
        Self.fresh {
            var slots = Set<UInt8>()
            for index in 0..<TaskRegistry.capacity {
                guard let control = Self.create(UInt(index)) else {
                    Issue.record("slot \(index) was refused")
                    return
                }
                slots.insert(control.slot)
            }

            #expect(slots.count == TaskRegistry.capacity)
            #expect(Self.create(99) == nil)
        }
    }


    @Test("a reused slot refuses the control of the task it held before")
    func staleGeneration() {
        Self.fresh {
            guard let first = Self.create(1) else { return }
            #expect(TaskRegistry.markAborted(first) == Self.construction(1))
            TaskRegistry.markProcessGone(first)
            #expect(!TaskRegistry.isLive(first))

            guard let second = Self.create(2) else { return }
            #expect(second.slot == first.slot)
            #expect(second.generation != first.generation)

            #expect(!TaskRegistry.isLive(first))
            #expect(!TaskRegistry.isOwned(first, by: Self.owner))
            #expect(TaskRegistry.configuring(first) == nil)
            #expect(TaskRegistry.status(first).0 == .invalid)
            #expect(TaskRegistry.markRunning(first) == nil)
            #expect(TaskRegistry.markAborted(first) == nil)
            #expect(TaskRegistry.status(second).0 == .configuring)

            // A stale release must not take the new task's only reference.
            TaskRegistry.retain(second)
            TaskRegistry.release(first)
            #expect(TaskRegistry.markExited(second, code: 0) == Self.construction(2))
            TaskRegistry.markProcessGone(second)
            #expect(TaskRegistry.isLive(second))

            TaskRegistry.release(second)
            #expect(!TaskRegistry.isLive(second))
        }
    }


    @Test("a forged control names nothing")
    func forgedControl() {
        Self.fresh {
            guard let real = Self.create(1) else { return }

            let wrongGeneration = TaskControl(slot: real.slot, generation: real.generation &+ 1)
            let pastTable       = TaskControl(slot: UInt8(TaskRegistry.capacity), generation: real.generation)
            let lastSlot        = TaskControl(slot: UInt8.max, generation: 1)
            let empty           = TaskControl(slot: real.slot &+ 1, generation: 0)

            for forged in [wrongGeneration, pastTable, lastSlot, empty] {
                #expect(!TaskRegistry.isLive(forged))
                #expect(!TaskRegistry.isOwned(forged, by: Self.owner))
                #expect(TaskRegistry.configuring(forged) == nil)
                #expect(TaskRegistry.runningProcess(forged) == nil)
                #expect(TaskRegistry.status(forged).0 == .invalid)
            }

            #expect(TaskRegistry.control(at: TaskRegistry.capacity, ownedBy: Self.owner) == nil)
        }
    }


    @Test("ownership is the creator's identity and nobody else's")
    func ownership() {
        Self.fresh {
            guard let control = Self.create(1) else { return }

            #expect(TaskRegistry.isOwned(control, by: Self.owner))
            #expect(!TaskRegistry.isOwned(control, by: Self.stranger))
            #expect(TaskRegistry.control(at: Int(control.slot), ownedBy: Self.owner) == control)
            #expect(TaskRegistry.control(at: Int(control.slot), ownedBy: Self.stranger) == nil)
            #expect(TaskRegistry.control(at: Int(control.slot) + 1, ownedBy: Self.owner) == nil)
        }
    }


    // MARK: - Lifecycle

    @Test("start hands the construction back once and leaves no configuring view")
    func startHandsBackOnce() {
        Self.fresh {
            guard let control = Self.create(1) else { return }

            #expect(TaskRegistry.configuring(control)?.construction == Self.construction(1))
            #expect(TaskRegistry.configuring(control)?.process == Self.process)
            #expect(TaskRegistry.runningProcess(control) == nil)

            #expect(TaskRegistry.markRunning(control) == Self.construction(1))
            #expect(TaskRegistry.markRunning(control) == nil)
            #expect(TaskRegistry.configuring(control) == nil)
            #expect(TaskRegistry.runningProcess(control) == Self.process)
            #expect(TaskRegistry.status(control).0 == .running)

            #expect(TaskRegistry.markAborted(control) == nil)
            #expect(TaskRegistry.status(control).0 == .aborted)
        }
    }


    @Test("an exit or an abort before start hands the construction back, and only once")
    func endBeforeStartHandsBack() {
        Self.fresh {
            guard let exited  = Self.create(1),
                  let aborted = Self.create(2)
            else { return }

            #expect(TaskRegistry.markExited(exited, code: 42) == Self.construction(1))
            #expect(TaskRegistry.status(exited) == (.exited, 42))
            #expect(TaskRegistry.markExited(exited, code: 43) == nil)
            #expect(TaskRegistry.markRunning(exited) == nil)

            #expect(TaskRegistry.markAborted(aborted) == Self.construction(2))
            #expect(TaskRegistry.status(aborted).0 == .aborted)
            #expect(TaskRegistry.markAborted(aborted) == nil)
            #expect(TaskRegistry.configuring(aborted) == nil)
        }
    }


    // MARK: - Collection

    @Test("the last capability dropped after the process is gone collects the record")
    func capabilityDroppedLast() {
        Self.fresh {
            guard let control = Self.create(1) else { return }
            TaskRegistry.retain(control)
            TaskRegistry.retain(control)
            _ = TaskRegistry.markRunning(control)
            _ = TaskRegistry.markExited(control, code: 3)
            TaskRegistry.markProcessGone(control)

            #expect(TaskRegistry.status(control) == (.exited, 3))
            TaskRegistry.release(control)
            #expect(TaskRegistry.isLive(control))
            TaskRegistry.release(control)
            #expect(!TaskRegistry.isLive(control))
        }
    }


    @Test("a process gone after the last capability collects the record")
    func processGoneLast() {
        Self.fresh {
            guard let control = Self.create(1) else { return }
            TaskRegistry.retain(control)
            _ = TaskRegistry.markRunning(control)

            TaskRegistry.release(control)
            #expect(TaskRegistry.isLive(control))

            _ = TaskRegistry.markExited(control, code: 0)
            #expect(TaskRegistry.isLive(control))
            TaskRegistry.markProcessGone(control)
            #expect(!TaskRegistry.isLive(control))
        }
    }


    @Test("a task still configuring or running is never collected")
    func liveStatesAreKept() {
        Self.fresh {
            guard let configuring = Self.create(1),
                  let running     = Self.create(2)
            else { return }
            _ = TaskRegistry.markRunning(running)

            for control in [configuring, running] {
                TaskRegistry.retain(control)
                TaskRegistry.release(control)
                TaskRegistry.markProcessGone(control)
                #expect(TaskRegistry.isLive(control))
            }
        }
    }


    @Test("a release with no reference left changes nothing")
    func releaseAtZero() {
        Self.fresh {
            guard let control = Self.create(1) else { return }
            _ = TaskRegistry.markAborted(control)

            TaskRegistry.release(control)
            #expect(TaskRegistry.isLive(control))

            TaskRegistry.retain(control)
            TaskRegistry.markProcessGone(control)
            #expect(TaskRegistry.isLive(control))
            TaskRegistry.release(control)
            #expect(!TaskRegistry.isLive(control))
        }
    }


    @Test("the reference count saturates instead of wrapping")
    func retainSaturates() {
        Self.fresh {
            guard let control = Self.create(1) else { return }
            _ = TaskRegistry.markAborted(control)

            for _ in 0...Int(UInt16.max) { TaskRegistry.retain(control) }
            TaskRegistry.markProcessGone(control)
            for _ in 0..<(Int(UInt16.max) - 1) { TaskRegistry.release(control) }
            #expect(TaskRegistry.isLive(control))

            TaskRegistry.release(control)
            #expect(!TaskRegistry.isLive(control))
        }
    }


    // MARK: - Fixtures

    private static func fresh(_ body: () -> Void) {
        TaskRegistry.resetForTesting()
        defer { TaskRegistry.resetForTesting() }
        body()
    }

    private static func create(_ tag: UInt) -> TaskControl? {
        TaskRegistry.create(owner: owner, process: process, construction: construction(tag))
    }
}
}
