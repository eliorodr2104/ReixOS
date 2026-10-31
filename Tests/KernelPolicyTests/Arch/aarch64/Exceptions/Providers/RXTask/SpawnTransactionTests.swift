//
//  SpawnTransactionTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

extension KernelPolicyTestRoot {
@Suite("Spawn transaction", .serialized)
struct SpawnTransactionTests {

    @Test("a missing grant aborts the suspended child before scheduling")
    func missingGrantRollsBack() {
        withProcessManager(pages: 128) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let parent = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create the parent")
                return
            }

            let source = parent.pointee.metadata.pointee.capsTable.install(
                Capability(target: .power, badge: 0, rights: [.grant, .write])
            )!

            let freeBefore = ram.ppm.pointee.totalPages - ram.ppm.pointee.allocatedPages

            guard let child = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create the suspended child")
                return
            }
            let childPID = child.pointee.pid

            var grants = InlineArray<2, CapGrant>(repeating: CapGrant())
            grants[0] = CapGrant(
                source: source,
                slot  : BootCap.power.rawValue,
                rights: [.write]
            )
            grants[1] = CapGrant(
                source: UInt32.max,
                slot  : BootCap.console.rawValue,
                rights: [.send]
            )

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            let outcome = withUnsafePointer(to: &grants) {
                SpawnProcessSyscall.commit(
                    child,
                    parent : parent,
                    grants : UnsafeRawPointer($0).assumingMemoryBound(to: CapGrant.self),
                    count  : 2,
                    context: context
                )
            }

            #expect(outcome == nil)
            #expect(parent.pointee.family.firstChild == nil)
            #expect(scheduler.pointee.search(in: .ready, to: childPID) == nil)
            #expect(ProcessStatsIndex.successor(after: parent.pointee.pid) == nil)
            #expect(parent.pointee.metadata.pointee.capsTable.resolve(source) != nil)
            #expect(ram.ppm.pointee.totalPages - ram.ppm.pointee.allocatedPages == freeBefore)
        }
    }

    @Test("grant preflight rejects duplicate slots and lossy rights")
    func malformedPlansAreRefused() {
        withProcessManager(pages: 64) { _, _, manager in
            guard let parent = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create the parent")
                return
            }

            let source = parent.pointee.metadata.pointee.capsTable.install(
                Capability(target: .power, badge: 0, rights: [.grant, .write])
            )!

            var grants = InlineArray<2, CapGrant>(repeating: CapGrant())
            grants[0] = CapGrant(source: source, slot: 4, rights: [.write])
            grants[1] = CapGrant(source: source, slot: 4, rights: [.write])

            let duplicate = withUnsafePointer(to: &grants) {
                SpawnProcessSyscall.validateGrantPlan(
                    UnsafeRawPointer($0).assumingMemoryBound(to: CapGrant.self),
                    count: 2,
                    from : parent
                )
            }
            #expect(!duplicate)

            grants[1].targetSlot = 5
            grants[1].rights = UInt32(UInt16.max) + 1

            let lossy = withUnsafePointer(to: &grants) {
                SpawnProcessSyscall.validateGrantPlan(
                    UnsafeRawPointer($0).assumingMemoryBound(to: CapGrant.self),
                    count: 2,
                    from : parent
                )
            }
            #expect(!lossy)
        }
    }
}
}
