//
//  ProcessManagerFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel

public func withProcessManager(
    pages : Int,
    _ body: (HostRAM, UnsafeMutablePointer<KernelHeap>, UnsafeMutablePointer<ProcessManager>) -> Void
) {
    withHostRAM(pages: pages) { ram in
        ram.installLiveManager()
        #expect(ram.donateAll())

        let saved = PPMBackend.physicalOffset
        PPMBackend.physicalOffset = 0
        ProcessStatsIndex.reset()
        defer {
            ProcessStatsIndex.reset()
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
        let fileSystem = UnsafeMutablePointer<KernelInternalFileSystem>.allocate(capacity: 1)
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


