//
//  ForkSpawnTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// `ProcessManager.spawnProcess()`, the fork-like path behind the `split`
/// syscall.
///
/// Never executed by anything before this suite: no host test named it, no row
/// of the boot matrix reaches it, and no userland program calls the `split`
/// wrapper. It was even refactored in that state, on static evidence alone.
/// What it does is allocate an address space, a VMA manager, a trap frame, a
/// metadata block and a process record, in that order, with a rollback for each
/// of the four ways the sequence can stop half-built.
///
/// Runs against a real allocator, heap and VMA manager over a host arena, and a
/// `VirtualMemoryManager` built through the host seam because the real one
/// panics off the machine (see `init(hostPPM:identityTable:)`).
///
/// `.serialized`, and the run needs `--no-parallel`: `PPMBackend.physicalOffset`
/// and `ProcessStatsIndex` are global, and every spawn registers into the
/// second one.
@Suite("Fork-like spawn", .serialized)
struct ForkSpawnTests {

    @Test("a fresh child gets an address space of its own")
    func ownAddressSpace() {
        withProcessManager(pages: 64) { ram, _, manager in
            guard let child = try? manager.pointee.spawnProcess() else {
                Issue.record("spawnProcess() failed on a 64-page arena")
                return
            }

            let space = child.pointee.addressSpace

            #expect(space.rootTablePhysical != 0)
            #expect(space.rootTablePhysical != ram.rootTablePhysical)
            #expect(space.vmaManager != nil)

            // Two children must not share a root, which is the whole point of
            // the allocation: same table would mean same memory.
            guard let second = try? manager.pointee.spawnProcess() else {
                Issue.record("second spawnProcess() failed")
                return
            }
            #expect(second.pointee.addressSpace.rootTablePhysical != space.rootTablePhysical)
            #expect(second.pointee.addressSpace.asid != space.asid)
        }
    }


    @Test("a fresh child carries no authority")
    func noInheritedAuthority() {
        withProcessManager(pages: 64) { _, _, manager in
            guard let child = try? manager.pointee.spawnProcess(),
                  let metadata = child.pointee.metadata else {
                Issue.record("spawnProcess() failed")
                return
            }

            // The fork-like spawn hands out an empty table on purpose: the
            // child's authority arrives afterwards, and only through
            // `cloneCapsTable`. A capability appearing here would be one no
            // caller asked for and nothing retained.
            for slot in 0..<16 {
                #expect(metadata.pointee.capsTable.resolve(UInt32(slot)) == nil)
            }
            #expect(metadata.pointee.capsTable.hasFreeSlot())
            #expect(metadata.pointee.parentEndpoint == nil)
            #expect(metadata.pointee.deviceCap == nil)
            #expect(metadata.pointee.elfImage == nil)
        }
    }


    @Test("the trap frame is armed for a process that has not run yet")
    func trapFrameArmed() {
        withProcessManager(pages: 64) { _, _, manager in
            guard let child = try? manager.pointee.spawnProcess(),
                  let context = child.pointee.context else {
                Issue.record("spawnProcess() failed")
                return
            }

            // The caller of `split` overwrites elr with the parent's, so zero
            // here is the "nothing to return to yet" the syscall relies on.
            #expect(context.pointee.elr   == 0)
            #expect(context.pointee.spsr  == 0)
            #expect(context.pointee.spel0 == UserSpaceLayout.stackTop)
        }
    }


    @Test("pids and badges are fresh and never reused")
    func freshIdentities() {
        withProcessManager(pages: 96) { _, _, manager in
            var pids   : [PID] = []
            var badges : [Identity] = []

            for _ in 0..<4 {
                guard let child = try? manager.pointee.spawnProcess() else {
                    Issue.record("spawnProcess() failed")
                    return
                }
                pids.append(child.pointee.pid)
                badges.append(child.pointee.identity)
            }

            #expect(Set(pids).count == pids.count)
            #expect(Set(badges).count == badges.count)
            #expect(pids == pids.sorted())
            #expect(!pids.contains(0)) // 0 is the kernel's own in every trace
        }
    }


    @Test("the child inherits the running process's name")
    func inheritsName() {
        withProcessManager(pages: 64) { _, _, manager in
            let parentMetadata = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
            parentMetadata.initialize(to: ProcessMetadata())
            defer { parentMetadata.deinitialize(count: 1); parentMetadata.deallocate() }

            let name: [UInt8] = Array("forked.elf".utf8)
            name.withUnsafeBufferPointer {
                parentMetadata.pointee.setName(from: $0.baseAddress!, count: $0.count)
            }

            let parent = makeProcess(pid: 40)
            defer { destroyProcess(parent) }
            parent.pointee.metadata = parentMetadata

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))

            guard let child = try? manager.pointee.spawnProcess(),
                  let metadata = child.pointee.metadata else {
                Issue.record("spawnProcess() failed")
                return
            }

            #expect(metadata.pointee.nameLength == UInt8(name.count))
            for index in 0..<name.count {
                #expect(metadata.pointee.name[index] == name[index])
            }
        }
    }


    @Test("a spawn with no parent to copy from is still named nothing, not garbage")
    func noParentNoName() {
        withProcessManager(pages: 64) { _, _, manager in
            Arch.CPU.setCurrentProcess(0)

            guard let child = try? manager.pointee.spawnProcess(),
                  let metadata = child.pointee.metadata else {
                Issue.record("spawnProcess() failed")
                return
            }

            #expect(metadata.pointee.nameLength == 0)
            for index in 0..<16 {
                #expect(metadata.pointee.name[index] == 0)
            }
        }
    }


    /// Take one block of every size the spawn will ask for and give it back, so
    /// the slab already owns a page for each class involved.
    ///
    /// Without this the first allocation of a size class pulls a fresh frame and
    /// keeps it in the slab, which is a legitimate consumption the rollback is
    /// not supposed to undo, and it would show up as a leak below.
    private func warmSlab(_ heap: UnsafeMutablePointer<KernelHeap>) {
        let sizes = [
            UInt(MemoryLayout<VMAManager>.stride),
            UInt(MemoryLayout<Arch.TrapFrame>.stride),
            UInt(MemoryLayout<ProcessMetadata>.stride),
            UInt(MemoryLayout<Process>.stride),
        ]

        let blocks = sizes.compactMap { heap.pointee.kmallocOrNil($0) }
        #expect(blocks.count == sizes.count)

        for block in blocks { heap.pointee.kfree(block) }
    }


    @Test("every rollback in the spawn sequence gives back what it took")
    func rollbacksAreComplete() {
        // The spawn makes four heap allocations after creating the address
        // space: the VMA manager, the trap frame, the metadata block and the
        // process record. Failing the nth is the only way to reach the nth
        // rollback, which is why the heap has a fault-injection seam at all.
        for surviving in 0..<4 {
            withProcessManager(pages: 64) { ram, heap, manager in
                warmSlab(heap)

                let freeBefore = ram.ppm.pointee.totalPages - ram.ppm.pointee.allocatedPages

                KernelHeap.failAllocationsAfter = surviving
                let outcome = try? manager.pointee.spawnProcess()
                KernelHeap.failAllocationsAfter = nil

                // The point of the seam: the spawn has to actually fail, and it
                // has to fail at the step this iteration aimed at.
                #expect(outcome == nil)

                let freeAfter = ram.ppm.pointee.totalPages - ram.ppm.pointee.allocatedPages

                // The address space's root table is the one frame the sequence
                // takes before any of these steps can fail. Every rollback owes
                // it back, and a heap block left behind shows up here too, as
                // the slab page it forced.
                #expect(freeAfter == freeBefore)
            }
        }
    }


    @Test("a failing spawn is repeatable, and never returns a half-built process")
    func failureIsRepeatable() {
        withProcessManager(pages: 64) { ram, heap, manager in
            warmSlab(heap)

            let freeBefore = ram.ppm.pointee.totalPages - ram.ppm.pointee.allocatedPages

            // Twenty failures at a rotating step. A rollback that misses a
            // frame shows up as this climbing rather than holding.
            for attempt in 0..<20 {
                KernelHeap.failAllocationsAfter = attempt % 4
                #expect((try? manager.pointee.spawnProcess()) == nil)
            }
            KernelHeap.failAllocationsAfter = nil

            #expect(ram.ppm.pointee.totalPages - ram.ppm.pointee.allocatedPages == freeBefore)

            // And the manager is still usable afterwards: a rollback that left
            // the allocator or the pid counter inconsistent would surface here.
            guard let child = try? manager.pointee.spawnProcess() else {
                Issue.record("the manager was left unusable by the failed attempts")
                return
            }
            #expect(child.pointee.addressSpace.rootTablePhysical != 0)
            #expect(child.pointee.metadata != nil)
            #expect(child.pointee.context  != nil)
        }
    }
}
