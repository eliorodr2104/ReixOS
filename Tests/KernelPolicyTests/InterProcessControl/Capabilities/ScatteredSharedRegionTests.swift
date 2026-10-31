//
//  ScatteredSharedRegionTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// A shared region is a set of buddy blocks, not one: what that buys, and that
/// every way of making or losing one gives back exactly what it took.
///
/// Two things the single-block region got wrong are the reason it changed. A
/// region needed one free block of its rounded-up order, so a fragmented
/// machine with frames to spare refused it; and a five-page region held eight
/// frames while its creator was charged for five.
///
/// `.serialized`, and the run needs `--no-parallel`, for `ForkSpawnTests`'
/// reason: `PPMBackend.physicalOffset`, `ProcessStatsIndex` and both fault
/// injection seams are global, and every test that arms one puts it back.
extension KernelPolicyTestRoot {
@Suite("Scattered shared regions", .serialized)
struct ScatteredSharedRegionTests {

    private static let page = UserSpaceLayout.pageSize

    private typealias Region = UnsafeMutablePointer<SharedRegion>


    // MARK: - Fixture

    private func withWorld(
        pages : Int,
        _ body: (
            HostRAM,
            UnsafeMutablePointer<KernelHeap>,
            UnsafeMutablePointer<ProcessManager>,
            UnsafeMutablePointer<KernelIPC>,
            SyscallContext
        ) -> Void
    ) {
        withProcessManager(pages: pages) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            body(ram, heap, manager, ipc, SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))
        }
    }


    /// `shmCreate(pages)` as `process`: the handle, window and region, or `nil`
    /// when it was refused, after checking a refusal wrote both registers.
    private func create(
        pages    : UInt64,
        as process: UnsafeMutablePointer<Process>,
        _ context: SyscallContext
    ) -> (handle: UInt32, address: VirtualAddress, region: Region)? {

        let frame = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        frame.initialize(to: Arch.TrapFrame())
        defer { frame.deinitialize(count: 1); frame.deallocate() }

        frame.pointee.x0 = pages

        withCurrentProcess(process) {
            ShmCreate.handle(frame: frame, context: context)
        }

        guard frame.pointee.x0 != UInt64.max else {
            #expect(frame.pointee.x1 == 0)
            return nil
        }

        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)

        guard let capability = process.pointee.metadata.pointee.capsTable.resolve(handle),
              case .shared(let region) = capability.target
        else {
            Issue.record("the minted capability does not name a region")
            return nil
        }

        return (handle, frame.pointee.x1, region)
    }


    /// Drops `process`'s capability and its window, in that order.
    private func drop(
        _ handle : UInt32,
        window   : VirtualAddress,
        pages    : UInt64,
        of process: UnsafeMutablePointer<Process>,
        _ ipc    : UnsafeMutablePointer<KernelIPC>
    ) {
        _ = ipc.pointee.releaseCapability(handle, of: process)

        #expect((try? process.pointee.addressSpace.vmaManager?.pointee.munmapRegion(
            addr: window,
            size: Self.page * pages
        )) == .completed)
    }


    /// The frame `process` maps at `virtual`, through its own page tables.
    private func frame(
        _ ram     : HostRAM,
        of process: UnsafeMutablePointer<Process>,
        at virtual: VirtualAddress
    ) -> PhysicalAddress? {
        ram.vmm.pointee.physicalAddressOf(
            rootTable: process.pointee.addressSpace.rootTablePhysical,
            virtual  : virtual
        )
    }


    private func budget(
        of process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<FrameBudget> {
        process.pointee.metadata.pointee.budget
    }


    /// Every frame of `region`, page by page.
    private func frames(of region: Region) -> [PhysicalAddress] {
        (0..<region.pointee.pageCount).map { region.pointee.physicalAddress(ofPage: $0) }
    }


    /// Frames the extents of `region` cover, which is what it holds.
    private func held(by region: Region) -> UInt32 {
        (0..<Int(region.pointee.extentCount)).reduce(0) { $0 + region.pointee.extent($1).pages }
    }


    /// A region made and dropped, so the slab and the tables a first region
    /// pulls in are already there when a test takes its baseline.
    private func prime(
        _ process: UnsafeMutablePointer<Process>,
        pages    : UInt64,
        _ ipc    : UnsafeMutablePointer<KernelIPC>,
        _ context: SyscallContext
    ) {
        guard let primed = create(pages: pages, as: process, context) else {
            Issue.record("could not prime the fixture")
            return
        }

        drop(primed.handle, window: primed.address, pages: pages, of: process, ipc)
    }


    // MARK: - Fragmentation

    @Test("a region larger than any free block is served from scattered frames")
    func fragmentedMachineServesTheRegion() {
        withWorld(pages: 128) { ram, heap, manager, ipc, context in
            guard let creator = try? manager.pointee.spawnProcess() else { return }

            ram.checkerboard()
            prime(creator, pages: 8, ipc, context)

            let baseline = ram.ppm.pointee.allocatedPages
            let live     = heap.pointee.metricsLiveBytes
            let before   = budget(of: creator).pointee.charged

            // What the single-block region asked for, and the machine refuses.
            #expect((try? ram.ppm.pointee.alloc(Int(Self.page) * 8)) == nil)

            guard let created = create(pages: 8, as: creator, context) else {
                Issue.record("a fragmented machine with frames to spare refused the region")
                return
            }

            let region = created.region
            let pages  = frames(of: region)

            #expect(region.pointee.extentCount == 8)
            #expect(Set(pages).count == 8)
            #expect(budget(of: creator).pointee.charged >= before + 8)

            for (index, physical) in pages.enumerated() {
                #expect(frame(ram, of: creator, at: created.address + UInt64(index) * Self.page) == physical)
                #expect(ram.ppm.pointee.refCount(of: physical) == 1)
            }

            drop(created.handle, window: created.address, pages: 8, of: creator, ipc)

            for physical in pages { #expect(ram.ppm.pointee.refCount(of: physical) == 0) }
            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(heap.pointee.metricsLiveBytes == live)
            #expect(budget(of: creator).pointee.charged == before)
        }
    }


    // MARK: - Exact size

    @Test("a region holds exactly its page count, in binary blocks", arguments: [3, 5, 7, 256])
    func regionHoldsExactlyItsPages(pages: Int) {
        withWorld(pages: 1024) { ram, _, manager, ipc, _ in
            guard let creator = try? manager.pointee.spawnProcess() else { return }

            let count = UInt32(pages)

            // Kept alive, so the slab page under both cells is not counted as a
            // frame below: a slab gives its page back once it is empty.
            guard case .success(let keeper) = ipc.pointee.createShared(for: creator, pageCount: 1) else {
                Issue.record("could not create the keeper")
                return
            }
            defer { _ = ipc.pointee.releaseCapability(keeper.handle, of: creator) }

            let baseline = ram.ppm.pointee.allocatedPages

            guard case .success(let created) = ipc.pointee.createShared(
                for      : creator,
                pageCount: count
            ) else {
                Issue.record("could not create the region")
                return
            }

            let region = created.region

            // `shmCreate` charges `pageCount`, so frames held equal the charge.
            #expect(ram.ppm.pointee.allocatedPages - baseline == UInt64(count))
            #expect(held(by: region) == count)
            #expect(Int(region.pointee.extentCount) == count.nonzeroBitCount)
            #expect(Set(frames(of: region)).count == pages)

            _ = ipc.pointee.releaseCapability(created.handle, of: creator)

            #expect(ram.ppm.pointee.allocatedPages == baseline)
        }
    }


    // MARK: - Unwinding

    @Test("a frame refused part-way gives back every block and the charge")
    func allocationFailingMidwayUnwinds() {
        withWorld(pages: 256) { ram, heap, manager, ipc, context in
            guard let creator = try? manager.pointee.spawnProcess() else { return }

            prime(creator, pages: 7, ipc, context)

            // Kept alive, so the region's cell needs no new slab page and the
            // one frame the injection lets through is the block of four.
            guard case .success(let keeper) = ipc.pointee.createShared(for: creator, pageCount: 1) else {
                Issue.record("could not create the keeper")
                return
            }
            defer { _ = ipc.pointee.releaseCapability(keeper.handle, of: creator) }

            let baseline   = ram.ppm.pointee.allocatedPages
            let live       = heap.pointee.metricsLiveBytes
            let before     = budget(of: creator).pointee.charged
            let references = budget(of: creator).pointee.references

            // Seven is four, two and one: the block of four is served, and
            // every order after it, down to zero, is refused.
            PPMFaultInjection.failAllocationsAfter = 1
            defer { PPMFaultInjection.failAllocationsAfter = nil }

            #expect(create(pages: 7, as: creator, context) == nil)
            #expect(PPMFaultInjection.failAllocationsAfter == 0)

            PPMFaultInjection.failAllocationsAfter = nil

            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(heap.pointee.metricsLiveBytes == live)
            #expect(budget(of: creator).pointee.charged == before)
            #expect(budget(of: creator).pointee.references == references)
        }
    }


    @Test("a spill the heap refuses gives back every block and the charge")
    func spillFailingUnwinds() {
        withWorld(pages: 128) { ram, heap, manager, ipc, context in
            guard let creator = try? manager.pointee.spawnProcess() else { return }

            ram.checkerboard()
            prime(creator, pages: 16, ipc, context)

            let baseline   = ram.ppm.pointee.allocatedPages
            let live       = heap.pointee.metricsLiveBytes
            let before     = budget(of: creator).pointee.charged
            let references = budget(of: creator).pointee.references

            // The region's own cell is served, its spill is not: sixteen
            // single frames are six more than the cell holds.
            KernelHeap.failAllocationsAfter = 1
            defer { KernelHeap.failAllocationsAfter = nil }

            #expect(create(pages: 16, as: creator, context) == nil)
            #expect(KernelHeap.failAllocationsAfter == 0)

            KernelHeap.failAllocationsAfter = nil

            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(heap.pointee.metricsLiveBytes == live)
            #expect(budget(of: creator).pointee.charged == before)
            #expect(budget(of: creator).pointee.references == references)
        }
    }


    @Test("a mapping refused mid-region gives back the frames, the spill and the charge")
    func mappingFailingMidwayUnwinds() {
        withWorld(pages: 128) { ram, heap, manager, ipc, context in
            guard let creator = try? manager.pointee.spawnProcess(),
                  let vma     = creator.pointee.addressSpace.vmaManager
            else { return }

            ram.checkerboard()
            prime(creator, pages: 16, ipc, context)

            // Where the window will go, the same question `mapRegion` asks.
            guard let start = vma.pointee.vmaList.findFreeGAPInRange(
                min      : UserSpaceLayout.mmapMin,
                max      : UserSpaceLayout.mmapBase,
                size     : Self.page * 16,
                alignment: Self.page,
                direction: .downward
            ), let squatter = try? ram.ppm.pointee.alloc(Int(Self.page)) else {
                Issue.record("could not stage the squatter")
                return
            }

            // A descriptor no VMA accounts for, on page 5 of the window, and a
            // second one just below it so the rollback leaves the table alone.
            for virtual in [start + 5 * Self.page, start - Self.page] {
                #expect((try? ram.vmm.pointee.installUserPage(
                    rootTable: creator.pointee.addressSpace.rootTablePhysical,
                    virtual  : virtual,
                    physical : squatter.address,
                    flags    : VMAPermissions([.read, .user]).toPageFlags(),
                    type     : .normal
                )) != nil)
            }

            let baseline   = ram.ppm.pointee.allocatedPages
            let live       = heap.pointee.metricsLiveBytes
            let before     = budget(of: creator).pointee.charged
            let references = budget(of: creator).pointee.references

            #expect(create(pages: 16, as: creator, context) == nil)

            #expect(vma.pointee.vmaList.search(at: start) == nil)
            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(heap.pointee.metricsLiveBytes == live)
            #expect(budget(of: creator).pointee.charged == before)
            #expect(budget(of: creator).pointee.references == references)
        }
    }


    @Test("a region whose capability cannot be installed is freed with its spill")
    func installFailingUnwinds() {
        withWorld(pages: 128) { ram, heap, manager, ipc, context in
            guard let creator = try? manager.pointee.spawnProcess() else { return }

            ram.checkerboard()
            prime(creator, pages: 16, ipc, context)

            let baseline   = ram.ppm.pointee.allocatedPages
            let live       = heap.pointee.metricsLiveBytes
            let before     = budget(of: creator).pointee.charged
            let references = budget(of: creator).pointee.references

            let table = creator.pointee.metadata.pointee.capsTable.caps.count
            var filled: [UInt32] = []
            for _ in 0..<table {
                guard let slot = creator.pointee.metadata.pointee.capsTable.install(
                    Capability(target: .clock, badge: Badge(0), rights: [.read])
                ) else { break }
                filled.append(slot)
            }

            #expect(create(pages: 16, as: creator, context) == nil)

            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(heap.pointee.metricsLiveBytes == live)
            #expect(budget(of: creator).pointee.charged == before)
            #expect(budget(of: creator).pointee.references == references)

            for slot in filled { _ = ipc.pointee.releaseCapability(slot, of: creator) }
        }
    }


    // MARK: - Spill lifecycle

    @Test("a spilled region lives and dies like any other", arguments: [true, false])
    func spilledRegionLifecycle(creatorDropsFirst: Bool) {
        withWorld(pages: 160) { ram, heap, manager, ipc, context in
            guard let creator  = try? manager.pointee.spawnProcess(),
                  let receiver = try? manager.pointee.spawnProcess(),
                  let receiverVMA = receiver.pointee.addressSpace.vmaManager
            else { return }

            ram.checkerboard()

            // Twice: the first pass pulls in the slabs and tables, the second is
            // measured against what the first left behind.
            for pass in 0..<2 {
                let baseline = ram.ppm.pointee.allocatedPages
                let live     = heap.pointee.metricsLiveBytes

                guard let created = create(pages: 20, as: creator, context),
                      case .success(let granted) = ipc.pointee.transferCapability(
                        from: creator, handler: created.handle,
                        to  : receiver, rights: [.read, .write]
                      ),
                      let window = try? receiverVMA.pointee.mapRegion(
                        created.region,
                        kind       : .shared,
                        permissions: [.read, .write, .user]
                      )
                else {
                    Issue.record("could not share the region")
                    return
                }

                let region = created.region
                let pages  = frames(of: region)

                // Twenty single frames: ten in the cell, ten spilled.
                #expect(region.pointee.extentCount == 20)
                #expect(held(by: region) == 20)
                #expect(Set(pages).count == 20)

                for (index, physical) in pages.enumerated() {
                    let offset = UInt64(index) * Self.page
                    #expect(frame(ram, of: creator,  at: created.address + offset) == physical)
                    #expect(frame(ram, of: receiver, at: window + offset) == physical)
                }

                let first  = creatorDropsFirst ? (creator,  created.handle, created.address)
                                               : (receiver, granted,        window)
                let second = creatorDropsFirst ? (receiver, granted,        window)
                                               : (creator,  created.handle, created.address)

                drop(first.1, window: first.2, pages: 20, of: first.0, ipc)

                for physical in pages { #expect(ram.ppm.pointee.refCount(of: physical) == 1) }
                #expect(region.pointee.references == 2)

                drop(second.1, window: second.2, pages: 20, of: second.0, ipc)

                for physical in pages { #expect(ram.ppm.pointee.refCount(of: physical) == 0) }

                if pass == 1 {
                    #expect(ram.ppm.pointee.allocatedPages == baseline)
                    #expect(heap.pointee.metricsLiveBytes == live)
                }
            }
        }
    }


    // MARK: - DMA

    @Test("a DMA buffer is still one block at the address the allocator chose")
    func dmaStaysOneBlock() {
        withWorld(pages: 128) { ram, _, manager, _, context in
            guard let caller = try? manager.pointee.spawnProcess(),
                  let device = caller.pointee.metadata.pointee.capsTable.install(
                    Capability(
                        target: .device(DeviceRegion(address: 0x0900_0000, size: 4096)),
                        badge : Badge(0),
                        rights: [.read, .write, .dma]
                    )
                  )
            else { return }

            let request = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            request.initialize(to: Arch.TrapFrame())
            defer { request.deinitialize(count: 1); request.deallocate() }

            // The block a five-page request is served from, given straight back:
            // the buffer below is the same request, so it gets the same block.
            guard let probe = try? ram.ppm.pointee.alloc(Int(Self.page) * 5) else {
                Issue.record("could not probe the allocator")
                return
            }
            let expected = probe.address
            #expect((try? ram.ppm.pointee.free(probe)) != nil)

            request.pointee.x0 = 5
            request.pointee.x1 = UInt64(device)
            withCurrentProcess(caller) { DmaAlloc.handle(frame: request, context: context) }

            guard request.pointee.x0 != UInt64.max,
                  let capability = caller.pointee.metadata.pointee.capsTable.resolve(
                      UInt32(truncatingIfNeeded: request.pointee.x0)
                  ),
                  case .dma(let buffer) = capability.target
            else {
                Issue.record("could not mint the DMA buffer")
                return
            }

            let window = request.pointee.x1

            #expect(buffer.pointee.extentCount == 1)
            #expect(buffer.pointee.extent(0).order == 3)
            #expect(buffer.pointee.extent(0).address == expected)

            for index in 0..<5 {
                let offset = UInt64(index) * Self.page
                #expect(frame(ram, of: caller, at: window + offset) == expected + offset)
            }

            var query = Arch.TrapFrame()
            query.x0 = request.pointee.x0
            withCurrentProcess(caller) { DmaPhysical.handle(frame: &query, context: context) }
            #expect(query.x0 == expected)

            // A buffer is never scattered: with no free block of two, two pages
            // are refused however many single frames are free.
            ram.checkerboard()

            request.pointee.x0 = 2
            request.pointee.x1 = UInt64(device)
            withCurrentProcess(caller) { DmaAlloc.handle(frame: request, context: context) }

            #expect(request.pointee.x0 == UInt64.max)
        }
    }
}
}
