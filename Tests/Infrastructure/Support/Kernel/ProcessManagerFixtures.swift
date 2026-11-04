//
//  ProcessManagerFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel

/// Whether the owner walk a teardown makes names only slots `identity` owns.
/// A walk that names another owner's slot would abort or kill that task, so a
/// test asks first and reports the wrong answer by name instead of running it.
public func teardownWalkIsOwned(by identity: Identity) -> Bool {
    for index in 0..<TaskRegistry.capacity {
        guard let control = TaskRegistry.control(at: index, ownedBy: identity) else { continue }
        guard TaskRegistry.isOwned(control, by: identity) else {
            Issue.record("the teardown walk names slot \(index), which identity \(identity) does not own")
            return false
        }
    }
    return true
}


public func withProcessManager(
    pages : Int,
    _ body: (HostRAM, UnsafeMutablePointer<KernelHeap>, UnsafeMutablePointer<ProcessManager>) -> Void
) {
    withKernelTestGlobals {
      withHostRAM(pages: pages) { ram in
        ram.installLiveManager()
        #expect(ram.donateAll())

        let saved = PPMBackend.physicalOffset
        PPMBackend.physicalOffset = 0
        ProcessStatsIndex.reset()
        DmaQuarantine.reset()
        defer {
            ProcessStatsIndex.reset()
            DmaQuarantine.reset()
            Arch.CPU.setCurrentProcess(0)
            PPMBackend.physicalOffset = saved
        }

        // The arena's spare root page stands in for the kernel master
        // table: zeroed, so a new address space starts with no descriptors
        // inherited rather than a copy of a mapping this suite never made.
        ram.vmm.pointee = VirtualMemoryManager(
            hostPPM      : ram.ppm,
            identityTable: ram.rootTablePhysical
        )

        let heap = UnsafeMutablePointer<KernelHeap>.allocate(capacity: 1)
        heap.initialize(to: KernelHeap(ppmPtr: ram.ppm))
        defer { heap.deinitialize(count: 1); heap.deallocate() }

        // Never read on this path: the fork-like spawn loads no image.
        let fileSystem = UnsafeMutablePointer<TarFileSystem>.allocate(capacity: 1)
        fileSystem.initialize(to: TarFileSystem())
        defer { fileSystem.deinitialize(count: 1); fileSystem.deallocate() }

        let manager = UnsafeMutablePointer<ProcessManager>.allocate(capacity: 1)
        manager.initialize(to: ProcessManager(
            vmm: ram.vmm, ppm: ram.ppm, heap: heap, fileSystem: fileSystem
        ))
        defer { manager.deinitialize(count: 1); manager.deallocate() }

          body(ram, heap, manager)
      }
    }
}

