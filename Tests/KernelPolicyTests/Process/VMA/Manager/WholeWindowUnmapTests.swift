//
//  WholeWindowUnmapTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// An object window goes away whole, with no list or ownership change on refusal.
/// Run with `--no-parallel`: the host arena and DMA ledger are global.
extension KernelPolicyTestRoot {
@Suite("Whole-window unmap", .serialized)
struct WholeWindowUnmapTests {

    private func invalidLayout(_ call: () throws -> Void) -> Bool {
        do { try call() }
        catch VMAError.invalidLayout { return true }
        catch {}
        return false
    }


    private static let page = UserSpaceLayout.pageSize
    private static let device: PhysicalAddress = 0x0900_0000

    enum Window: CaseIterable, Sendable {
        case device, dma, shared, brk
    }

    enum Cut: UInt64, CaseIterable, Sendable {
        case start = 0, middle = 2, end = 4
    }

    private struct Fixture {
        let ram    : HostRAM
        let heap   : UnsafeMutablePointer<KernelHeap>
        let process: UnsafeMutablePointer<Process>
        let vma    : UnsafeMutablePointer<VMAManager>
        let ipc    : UnsafeMutablePointer<KernelIPC>
        let context: SyscallContext
        let address: VirtualAddress
        let handle : UInt32?
        let device : UInt32
        let region : UnsafeMutablePointer<SharedRegion>?
    }


    private func withWindow(_ kind: Window, publish: Bool = true, _ body: (Fixture) -> Void) {
        withProcessManager(pages: 256) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            let savedScheduler = Kernel.scheduler
            Kernel.scheduler = scheduler
            defer {
                Kernel.scheduler = savedScheduler
                UnsafeMutableRawPointer(scheduler).deallocate()
            }
            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }
            let context = SyscallContext(
                processManager: manager, scheduler: scheduler, ipc: ipc, ppm: ram.ppm
            )

            guard let process = try? manager.pointee.spawnProcess(),
                  let vma = process.pointee.addressSpace.vmaManager,
                  let device = process.pointee.metadata.pointee.capsTable.install(Capability(
                    target: .device(DeviceRegion(address: Self.device, size: 5 * Self.page)),
                    badge : Badge(0),
                    rights: [.read, .write, .dma]
                  ))
            else { Issue.record("could not create the window holder"); return }

            var frame = Arch.TrapFrame()
            var address: VirtualAddress = 0
            var handle : UInt32? = nil
            var region : UnsafeMutablePointer<SharedRegion>? = nil

            withCurrentProcess(process) {
                switch kind {
                    case .device:
                        frame.x0 = UInt64(device)
                        MapDeviceSyscall.handle(frame: &frame, context: context)
                        address = frame.x0

                    case .dma, .shared:
                        frame.x0 = 5
                        frame.x1 = UInt64(device)
                        if kind == .dma {
                            DmaAlloc.handle(frame: &frame, context: context)
                        } else {
                            ShmCreate.handle(frame: &frame, context: context)
                        }
                        guard frame.x0 != UInt64.max else { return }
                        handle  = UInt32(truncatingIfNeeded: frame.x0)
                        address = frame.x1
                        if let cap = process.pointee.metadata.pointee.capsTable.resolve(handle!) {
                            switch cap.target {
                                case .dma(let held), .shared(let held): region = held
                                default: break
                            }
                        }
                        if kind == .dma, publish {
                            frame.x0 = UInt64(handle!)
                            DmaPhysical.handle(frame: &frame, context: context)
                        }

                    case .brk:
                        address = UserSpaceLayout.elfBaseTypical
                        vma.pointee.setInitialBreak(address)
                        #expect(throws: Never.self) {
                            _ = try vma.pointee.extendBreak(to: address + 5 * Self.page)
                        }
                        for index in 0..<5 {
                            #expect(vma.pointee.handlePageFault(
                                at: address + UInt64(index) * Self.page,
                                cause: .translation, access: .write
                            ) == .handled)
                        }
                }
            }

            guard address != 0, address != UInt64.max,
                  (kind != .dma && kind != .shared) || region != nil
            else { Issue.record("could not map the object window"); return }

            body(Fixture(
                ram: ram, heap: heap, process: process, vma: vma, ipc: ipc,
                context: context, address: address, handle: handle, device: device, region: region
            ))
        }
    }


    private func nodes(_ vma: UnsafeMutablePointer<VMAManager>) -> [UInt64] {
        var result: [UInt64] = []
        var cursor = vma.pointee.vmaList.head
        while let node = cursor {
            let area = node.pointee
            result += [UInt64(UInt(bitPattern: node)), area.startAddress, area.endAddress,
                       area.permissions.rawValue, UInt64(area.mappingFlags.rawValue),
                       UInt64(UInt(bitPattern: area.prev)), UInt64(UInt(bitPattern: area.next))]
            cursor = area.next
        }
        return result
    }


    private func expectRefusal(
        _ fixture: Fixture,
        start    : VirtualAddress,
        size     : UInt64,
        rollback : Bool
    ) {
        let vma    = fixture.vma
        let budget = fixture.process.pointee.metadata.pointee.budget!
        let before = fixture.ram.pmmStateSnapshot()
        let list   = nodes(vma)
        let count  = vma.pointee.registeredRegions
        let mapped = vma.pointee.residentPages
        let live   = fixture.heap.pointee.metricsLiveBytes
        let charge = budget.pointee.charged
        let holds  = budget.pointee.references
        let refs   = fixture.region?.pointee.references
        let ledger = [DmaQuarantine.pages, DmaQuarantine.regions,
                      DmaQuarantine.refusedPages, DmaQuarantine.doubleFrees]
        let retired = PageRetirement.retiredPages

        #expect(invalidLayout {
            if rollback {
                try vma.pointee.rollbackMapping(addr: start, size: size)
            } else {
                _ = try vma.pointee.munmapRegion(addr: start, size: size)
            }
        })

        #expect(nodes(vma) == list)
        #expect(vma.pointee.registeredRegions == count)
        #expect(vma.pointee.residentPages == mapped)
        #expect(fixture.heap.pointee.metricsLiveBytes == live)
        #expect(budget.pointee.charged == charge)
        #expect(budget.pointee.references == holds)
        #expect(fixture.region?.pointee.references == refs)
        #expect([DmaQuarantine.pages, DmaQuarantine.regions,
                 DmaQuarantine.refusedPages, DmaQuarantine.doubleFrees] == ledger)
        #expect(PageRetirement.retiredPages == retired)
        let untouched = fixture.ram.pmmStateSnapshot() == before
        #expect(untouched, "the refusal changed arena bytes, including page tables and object metadata")
    }


    @Test("device cuts are refused before any mutation", arguments: Cut.allCases, [false, true])
    func devicePartialUnmapIsAtomic(_ cut: Cut, _ rollback: Bool) {
        partialUnmap(.device, cut: cut, rollback: rollback)
    }

    @Test("DMA cuts are refused before any mutation", arguments: Cut.allCases, [false, true])
    func dmaPartialUnmapIsAtomic(_ cut: Cut, _ rollback: Bool) {
        partialUnmap(.dma, cut: cut, rollback: rollback)
    }

    @Test("SHM cuts are refused before any mutation", arguments: Cut.allCases, [false, true])
    func sharedPartialUnmapIsAtomic(_ cut: Cut, _ rollback: Bool) {
        partialUnmap(.shared, cut: cut, rollback: rollback)
    }

    @Test("brk keeps its whole-region rule", arguments: Cut.allCases, [false, true])
    func brkPartialUnmapIsAtomic(_ cut: Cut, _ rollback: Bool) {
        partialUnmap(.brk, cut: cut, rollback: rollback)
    }

    private func partialUnmap(_ kind: Window, cut: Cut, rollback: Bool) {
        for publish in kind == .dma ? [false, true] : [true] {
            withWindow(kind, publish: publish) { fixture in
                expectRefusal(
                    fixture, start: fixture.address + cut.rawValue * Self.page,
                    size: Self.page, rollback: rollback
                )
            }
        }
    }


    @Test("a later object refusal leaves an earlier anonymous edge unsplit",
          arguments: [Window.device, .dma, .shared], [false, true])
    func validatesBothEdgesBeforeSplitting(_ kind: Window, _ rollback: Bool) {
        withWindow(kind) { fixture in
            let start = fixture.address - 3 * Self.page
            #expect(throws: Never.self) {
                try fixture.vma.pointee.registerRegion(
                    start: start, size: 2 * Self.page,
                    permissions: [.read, .write, .user], backing: .anonymous,
                    flags: .noReserve, memoryType: .normal
                )
            }
            expectRefusal(
                fixture, start: start + Self.page, size: 3 * Self.page, rollback: rollback
            )
        }
    }


    @Test("exact and enclosing whole-window unmaps succeed",
          arguments: Window.allCases, [false, true])
    func wholeWindowUnmaps(_ kind: Window, _ enclosing: Bool) {
        withWindow(kind) { fixture in
            let margin = enclosing ? Self.page : 0
            #expect((try? fixture.vma.pointee.munmapRegion(
                addr: fixture.address - margin, size: 5 * Self.page + 2 * margin
            )) == .completed)
            #expect(fixture.vma.pointee.vmaList.search(at: fixture.address) == nil)
            for index in 0..<5 {
                #expect(!fixture.vma.pointee.isPageMapped(at: fixture.address + UInt64(index) * Self.page))
            }
            if let region = fixture.region {
                #expect(region.pointee.references == 1)
                #expect(DmaQuarantine.pages == 0)
                let physical = region.pointee.physicalAddress(ofPage: 0)
                let budget   = fixture.process.pointee.metadata.pointee.budget!
                let charged  = budget.pointee.charged
                _ = fixture.ipc.pointee.releaseCapability(fixture.handle!, of: fixture.process)

                if kind == .dma {
                    #expect(DmaQuarantine.pages == 8)
                    #expect(DmaQuarantine.regions == 1)
                    #expect(budget.pointee.charged == charged)
                    var frame = Arch.TrapFrame()
                    frame.x0 = UInt64(fixture.device)
                    withCurrentProcess(fixture.process) {
                        DmaReclaim.handle(frame: &frame, context: fixture.context)
                    }
                    #expect(frame.x0 == 8)
                    #expect(budget.pointee.charged == charged - 8)
                    #expect(DmaQuarantine.pages == 0)
                    #expect(DmaQuarantine.regions == 0)
                } else {
                    #expect(budget.pointee.charged == charged - 5)
                }
                #expect(fixture.ram.ppm.pointee.refCount(of: physical) == 0)
            }
            if kind == .brk { #expect(fixture.vma.pointee.brkVMA == nil) }
        }
    }


    @Test("the last window releases SHM or quarantines DMA after its capability goes",
          arguments: [Window.dma, .shared])
    func capabilityCanGoBeforeTheWindow(_ kind: Window) {
        withWindow(kind) { fixture in
            guard let region = fixture.region else { Issue.record("the object is missing"); return }
            let physical = region.pointee.physicalAddress(ofPage: 0)
            let budget   = fixture.process.pointee.metadata.pointee.budget!
            let charge   = budget.pointee.charged
            _ = fixture.ipc.pointee.releaseCapability(fixture.handle!, of: fixture.process)
            #expect(region.pointee.references == 1)
            #expect(budget.pointee.charged == charge)
            #expect((try? fixture.vma.pointee.munmapRegion(
                addr: fixture.address, size: 5 * Self.page
            )) == .completed)
            if kind == .dma {
                #expect(region.pointee.references == 0)
                #expect(DmaQuarantine.pages == 8)
                #expect(DmaQuarantine.regions == 1)
                #expect(fixture.ram.ppm.pointee.refCount(of: physical) == 1)
                let beforeReclaim = budget.pointee.charged
                var frame = Arch.TrapFrame()
                frame.x0 = UInt64(fixture.device)
                withCurrentProcess(fixture.process) {
                    DmaReclaim.handle(frame: &frame, context: fixture.context)
                }
                #expect(frame.x0 == 8)
                #expect(budget.pointee.charged == beforeReclaim - 8)
                #expect(DmaQuarantine.pages == 0)
                #expect(DmaQuarantine.regions == 0)
            }
            #expect(fixture.ram.ppm.pointee.refCount(of: physical) == 0)
        }
    }


    @Test("the list refuses direct object splits even at its node limit",
          arguments: [Window.device, .dma, .shared], [false, true])
    func directObjectSplitIsAtomic(_ kind: Window, _ atLimit: Bool) {
        withWindow(kind) { fixture in
            let vma = fixture.vma
            guard let node = vma.pointee.vmaList.search(at: fixture.address) else {
                Issue.record("the window lost its VMA"); return
            }
            if atLimit {
                for index in 0..<Int(vma.pointee.regionLimit - vma.pointee.registeredRegions) {
                    #expect(throws: Never.self) {
                        try vma.pointee.registerRegion(
                            start: UserSpaceLayout.elfBaseTypical + UInt64(index) * 2 * Self.page,
                            size: Self.page, permissions: [.read, .user],
                            backing: .anonymous, flags: .noReserve, memoryType: .normal
                        )
                    }
                }
            }
            let before = fixture.ram.pmmStateSnapshot()
            let list   = nodes(vma)
            #expect(invalidLayout {
                _ = try vma.pointee.vmaList.split(node, at: fixture.address + Self.page, using: fixture.heap)
            })
            #expect(nodes(vma) == list)
            let untouched = fixture.ram.pmmStateSnapshot() == before
            #expect(untouched)
        }
    }
}
}
