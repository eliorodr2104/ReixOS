//
//  FrameBudgetTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

/// The aggregate memory and metadata budget: what a process is charged for,
/// what gives it back, and what is refused once it has spent its ceiling.
///
/// The invariant every test here is an instance of: for a live process,
/// `framesCharged` equals the frames the kernel holds on its behalf, and once a
/// process is fully gone its charge is zero and the physical page manager is
/// back where it was.
///
/// `.serialized`, and the run needs `--no-parallel`, for `ForkSpawnTests`'
/// reason: `PPMBackend.physicalOffset`, `ProcessStatsIndex` and the two fault
/// injection seams are global, and every test that arms one puts it back.
extension KernelPolicyTestRoot {
@Suite("Frame budget", .serialized)
struct FrameBudgetTests {

    private static let page = UserSpaceLayout.pageSize


    private func budget(
        of process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<FrameBudget> {
        process.pointee.metadata.pointee.budget
    }


    private func charged(_ process: UnsafeMutablePointer<Process>) -> UInt32 {
        process.pointee.metadata.pointee.budget.pointee.charged
    }


    private func limit(_ process: UnsafeMutablePointer<Process>) -> UInt32 {
        process.pointee.metadata.pointee.budget.pointee.limit
    }


    private func setLimit(
        _ value  : UInt32,
        on process: UnsafeMutablePointer<Process>
    ) {
        process.pointee.metadata.pointee.budget.pointee.limit = value
    }


    /// Whether `body` refused with the PPM's own out-of-memory.
    private func refusedAsOutOfMemory(_ body: () throws -> Void) -> Bool {
        do { try body() }
        catch let error as PPMError { return error.reportedCause == .outOfMemory }
        catch { return false }

        return false
    }


    /// Whether `body` refused because the address space holds every region it may.
    private func refusedAsRegionLimit(_ body: () throws -> Void) -> Bool {
        do { try body() }
        catch let error as VMAError {
            if case .regionLimitReached = error { return true }
            return false
        }
        catch { return false }

        return false
    }


    // MARK: - The two operations

    @Test("a charge is refused whole, and a refund never wraps")
    func arithmetic() {
        var budget = FrameBudget(limit: 10, charged: 0)

        let filled = budget.charge(10)
        #expect(filled)
        #expect(budget.charged == 10)

        let overflowed = budget.charge(1)
        #expect(!overflowed)
        #expect(budget.charged == 10)

        budget.refund(4)
        #expect(budget.charged == 6)

        budget.refund(100)
        #expect(budget.charged == 0)

        var saturated  = FrameBudget(limit: .max, charged: UInt32.max - 1)
        let wrapped    = saturated.charge(5)
        #expect(!wrapped)
        #expect(saturated.charged == UInt32.max - 1)
    }


    @Test("a child's limit is the smaller of what it asks and what its parent has")
    func attenuation() {
        let parent = FrameBudget(limit: 100)

        #expect(parent.attenuated(to: nil)  == 100)
        #expect(parent.attenuated(to: 40)   == 40)
        #expect(parent.attenuated(to: 4000) == 100)

        let child = FrameBudget(limit: parent.attenuated(to: 40))
        #expect(child.attenuated(to: 4000) == 40)
        #expect(child.attenuated(to: 10)   == 10)
    }


    // MARK: - The invariant

    @Test("materialize, copy, unmap and teardown track the frames held")
    func chargeTracksFramesHeld() {
        withProcessManager(pages: 160) { ram, _, manager in
            let before = ram.ppm.pointee.allocatedPages

            guard let process = try? manager.pointee.spawnProcess(),
                  let vma     = process.pointee.addressSpace.vmaManager
            else {
                Issue.record("could not spawn the process under test")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: process)))
            defer { Arch.CPU.setCurrentProcess(0) }

            // The root table is the address space's own cost and is charged
            // before anything else runs.
            let afterSpawn = charged(process)
            #expect(afterSpawn >= 1)

            guard let address = try? vma.pointee.mmapAnonymous(
                size       : Self.page * 4,
                permissions: [.read, .write, .user]
            ) else {
                Issue.record("could not reserve the region")
                return
            }

            // A registration takes no frame: the region is lazily backed.
            #expect(charged(process) == afterSpawn)

            let heldBefore = ram.ppm.pointee.allocatedPages

            for index in 0..<4 {
                #expect(vma.pointee.handlePageFault(
                    at    : address + UInt64(index) * Self.page,
                    cause : .translation,
                    access: .write
                ) == .handled)
            }

            // Four data frames plus whatever levels of the walk were absent,
            // which is exactly what the manager took from the allocator.
            let held = ram.ppm.pointee.allocatedPages - heldBefore
            #expect(UInt64(charged(process)) == UInt64(afterSpawn) + held)

            #expect((try? vma.pointee.munmapRegion(
                addr: address,
                size : Self.page * 4
            )) == .completed)

            // The frames are back; the heap may keep the slab page the freed
            // VMA node came out of, so the count settles across the whole life.
            #expect(charged(process) == afterSpawn)
            #expect(ram.ppm.pointee.allocatedPages <= heldBefore)

            try? manager.pointee.releaseAddressSpace(process)
            #expect(charged(process) == 0)

            Arch.CPU.setCurrentProcess(0)
            manager.pointee.releaseProcess(process)

            #expect(ram.ppm.pointee.allocatedPages == before)
        }
    }


    // MARK: - Refusals at the ceiling

    @Test("a process at its limit is refused the next page, and pays nothing")
    func faultAtTheLimitIsRefused() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma     = process.pointee.addressSpace.vmaManager,
                  let address = try? vma.pointee.mmapAnonymous(
                    size       : Self.page,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not build the fixture")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: process)))
            defer { Arch.CPU.setCurrentProcess(0) }

            setLimit(charged(process), on: process)

            let snapshot = ram.pmmStateSnapshot()

            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .write
            ) == .outOfMemory)

            // Refused before the allocator, so no frame moved and no leaf
            // descriptor was written.
            #expect(ram.pmmStateSnapshot() == snapshot)
            #expect(!vma.pointee.isPageMapped(at: address))
            #expect(charged(process) == limit(process))
        }
    }


    @Test("a task map at the limit is refused with nothing half allocated")
    func taskMapAtTheLimitIsRefused() {
        withProcessManager(pages: 160) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let owner = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the task owner")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: owner)))
            defer { Arch.CPU.setCurrentProcess(0) }

            guard let created = manager.pointee.createSuspendedTask(ownedBy: owner) else {
                Issue.record("could not create the suspended task")
                return
            }

            let child = created.process
            setLimit(charged(child) + 2, on: child)

            let chargeBefore = charged(child)
            let heldBefore   = ram.ppm.pointee.allocatedPages
            let base         = UserSpaceLayout.elfBaseTypical

            #expect(manager.pointee.mapTaskAnonymous(
                created.control,
                at   : base,
                pages: 8
            ) == .outOfMemory)

            // Rolled back whole: the charge is where it was and not one page of
            // the range is resident.
            #expect(charged(child) == chargeBefore)
            #expect(ram.ppm.pointee.allocatedPages <= heldBefore)

            guard let childVMA = child.pointee.addressSpace.vmaManager else {
                Issue.record("the suspended task lost its VMA manager")
                return
            }

            for index in 0..<8 {
                #expect(!childVMA.pointee.isPageMapped(
                    at: base + UInt64(index) * Self.page
                ))
            }

            _ = manager.pointee.abortTask(created.control, context: SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))
        }
    }


    @Test("an SHM create and a DMA alloc at the limit are refused, and take nothing")
    func regionCreationAtTheLimitIsRefused() {
        withProcessManager(pages: 160) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let caller = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the caller")
                return
            }

            let device = caller.pointee.metadata.pointee.capsTable.install(
                Capability(
                    target: .device(DeviceRegion(address: 0x0900_0000, size: 4096)),
                    badge : Badge(0),
                    rights: [.read, .write, .dma]
                )
            )
            #expect(device != nil)

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: caller)))
            defer { Arch.CPU.setCurrentProcess(0) }

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            setLimit(charged(caller) + 1, on: caller)

            let snapshot = ram.pmmStateSnapshot()

            let shm = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            shm.initialize(to: Arch.TrapFrame())
            defer { shm.deinitialize(count: 1); shm.deallocate() }
            shm.pointee.x0 = 4

            ShmCreate.handle(frame: shm, context: context)

            #expect(shm.pointee.x0 == UInt64.max)
            #expect(shm.pointee.x1 == 0)
            #expect(ram.pmmStateSnapshot() == snapshot)

            let dma = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            dma.initialize(to: Arch.TrapFrame())
            defer { dma.deinitialize(count: 1); dma.deallocate() }
            dma.pointee.x0 = 4
            dma.pointee.x1 = UInt64(device ?? 0)

            DmaAlloc.handle(frame: dma, context: context)

            #expect(dma.pointee.x0 == UInt64.max)
            #expect(dma.pointee.x1 == 0)
            #expect(ram.pmmStateSnapshot() == snapshot)
        }
    }


    /// A caller, the IPC instance and the syscall context the region providers
    /// are handed, for the ownership tests below.
    private func withRegionCaller(
        _ body: (
            HostRAM,
            UnsafeMutablePointer<KernelHeap>,
            UnsafeMutablePointer<ProcessManager>,
            UnsafeMutablePointer<KernelIPC>,
            UnsafeMutablePointer<Process>,
            SyscallContext
        ) -> Void
    ) {
        withProcessManager(pages: 192) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let caller = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the caller")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: caller)))
            defer { Arch.CPU.setCurrentProcess(0) }

            body(ram, heap, manager, ipc, caller, SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))
        }
    }


    /// Runs `shmCreate(pages)` and answers its capability handle and window.
    private func createRegion(
        pages    : UInt64,
        _ context: SyscallContext,
        device   : UInt32? = nil
    ) -> (handle: UInt32, address: VirtualAddress)? {

        let request = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        request.initialize(to: Arch.TrapFrame())
        defer { request.deinitialize(count: 1); request.deallocate() }

        request.pointee.x0 = pages

        if let device {
            request.pointee.x1 = UInt64(device)
            DmaAlloc.handle(frame: request, context: context)

        } else {
            ShmCreate.handle(frame: request, context: context)
        }

        guard request.pointee.x0 != UInt64.max else {
            Issue.record("a region request that should have been served was refused")
            return nil
        }

        return (UInt32(truncatingIfNeeded: request.pointee.x0), request.pointee.x1)
    }


    @Test("the creator keeps paying while it holds the region another way")
    func regionStaysChargedWhileTheCreatorHoldsIt() {
        withRegionCaller { _, _, _, ipc, caller, context in
            guard let vma = caller.pointee.addressSpace.vmaManager else { return }

            let before = charged(caller)

            guard let region = createRegion(pages: 4, context) else { return }

            let held = charged(caller)
            #expect(held >= before + 4)

            // The capability goes and the window stays: every frame is still
            // mapped here, so every frame is still this process's to pay for.
            _ = ipc.pointee.releaseCapability(region.handle, of: caller)

            #expect(charged(caller) == held)
            #expect(vma.pointee.isPageMapped(at: region.address))
        }
    }


    @Test("unmapping one of two windows leaves the charge alone")
    func twoWindowsOneUnmapped() {
        withRegionCaller { _, _, _, ipc, caller, context in
            guard let vma    = caller.pointee.addressSpace.vmaManager,
                  let region = createRegion(pages: 4, context)
            else { return }

            let held = charged(caller)

            // A second window onto the same region, the way `shmMap` makes one.
            guard let capability = caller.pointee.metadata.pointee.capsTable.resolve(region.handle),
                  case .shared(let shared) = capability.target,
                  let second = try? vma.pointee.mapRegion(
                    physicalBase: shared.pointee.physicalPage.address,
                    pageCount   : 4,
                    kind        : .shared,
                    permissions : [.read, .write, .user],
                    sharedRegion: shared
                  )
            else {
                Issue.record("could not open a second window")
                return
            }

            #expect(charged(caller) == held)

            #expect((try? vma.pointee.munmapRegion(
                addr: second,
                size : Self.page * 4
            )) == .completed)

            // One window gone, one window and the capability left.
            #expect(charged(caller) == held)
            #expect(shared.pointee.owner != nil)
        }
    }


    @Test("the last reference to go kills the region and refunds once")
    func lastReferenceRefundsOnce() {
        withRegionCaller { ram, _, _, ipc, caller, context in
            guard let vma = caller.pointee.addressSpace.vmaManager else { return }

            let before = charged(caller)
            let frames = ram.ppm.pointee.allocatedPages

            guard let region = createRegion(pages: 4, context) else { return }

            #expect(charged(caller) >= before + 4)

            _ = ipc.pointee.releaseCapability(region.handle, of: caller)

            #expect((try? vma.pointee.munmapRegion(
                addr: region.address,
                size : Self.page * 4
            )) == .completed)

            // The region is gone: its four frames are back and so is the
            // charge, once and not twice.
            #expect(charged(caller) == before)
            #expect(ram.ppm.pointee.allocatedPages <= frames)
        }
    }


    @Test("a creator's teardown ends the charge of a region somebody else keeps")
    func tearingDownDisownsARegionThatSurvives() {
        withRegionCaller { ram, _, manager, ipc, caller, context in
            guard let region = createRegion(pages: 4, context) else { return }

            guard let capability = caller.pointee.metadata.pointee.capsTable.resolve(region.handle),
                  case .shared(let shared) = capability.target
            else {
                Issue.record("the region capability did not name a region")
                return
            }

            // A second process holds the region, so it outlives its creator.
            guard let keeper = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the keeper")
                return
            }

            guard case .success = ipc.pointee.transferCapability(
                from   : caller,
                handler: region.handle,
                to     : keeper,
                rights : [.read, .write]
            ) else {
                Issue.record("could not hand the region to the keeper")
                return
            }

            let budget = budget(of: caller)
            let frames = ram.ppm.pointee.allocatedPages

            try? manager.pointee.releaseAddressSpace(caller)
            ipc.pointee.releaseCapabilities(of: caller)

            // Disowned rather than freed: the keeper still has it.
            #expect(charged(caller) == 0)
            #expect(shared.pointee.owner == nil)
            #expect(ram.ppm.pointee.refCount(of: shared.pointee.physicalPage.address) > 0)
            #expect(ram.ppm.pointee.allocatedPages <= frames)

            // And the region's later death refunds nobody.
            let chargedAfter = budget.pointee.charged
            ipc.pointee.releaseCapabilities(of: keeper)
            #expect(budget.pointee.charged == chargedAfter)

            Arch.CPU.setCurrentProcess(0)
            manager.pointee.releaseProcess(caller)
        }
    }


    @Test("a teardown disowns a region the dying process holds only by capability")
    func tearingDownDisownsACapabilityOnlyRegion() {
        withRegionCaller { ram, _, manager, ipc, caller, context in
            guard let vma    = caller.pointee.addressSpace.vmaManager,
                  let region = createRegion(pages: 4, context)
            else { return }

            guard let capability = caller.pointee.metadata.pointee.capsTable.resolve(region.handle),
                  case .shared(let shared) = capability.target
            else {
                Issue.record("the region capability did not name a region")
                return
            }

            guard let keeper = try? manager.pointee.spawnProcess(),
                  case .success = ipc.pointee.transferCapability(
                    from   : caller,
                    handler: region.handle,
                    to     : keeper,
                    rights : [.read, .write]
                  )
            else {
                Issue.record("could not hand the region to the keeper")
                return
            }

            // The window goes while the process lives, so only the capability
            // names the region and only `releaseCapabilities` can disown it.
            #expect((try? vma.pointee.munmapRegion(
                addr: region.address,
                size : Self.page * 4
            )) == .completed)

            #expect(shared.pointee.owner != nil)

            try? manager.pointee.releaseAddressSpace(caller)
            ipc.pointee.releaseCapabilities(of: caller)

            #expect(charged(caller) == 0)
            #expect(shared.pointee.owner == nil)
            #expect(ram.ppm.pointee.refCount(of: shared.pointee.physicalPage.address) > 0)

            Arch.CPU.setCurrentProcess(0)
            manager.pointee.releaseProcess(caller)
        }
    }


    @Test("a teardown disowns a region the dying process holds only by a window")
    func tearingDownDisownsAWindowOnlyRegion() {
        withRegionCaller { ram, _, manager, ipc, caller, context in
            guard let region = createRegion(pages: 4, context) else { return }

            guard let capability = caller.pointee.metadata.pointee.capsTable.resolve(region.handle),
                  case .shared(let shared) = capability.target
            else {
                Issue.record("the region capability did not name a region")
                return
            }

            guard let keeper = try? manager.pointee.spawnProcess(),
                  case .success = ipc.pointee.transferCapability(
                    from   : caller,
                    handler: region.handle,
                    to     : keeper,
                    rights : [.read, .write]
                  )
            else {
                Issue.record("could not hand the region to the keeper")
                return
            }

            // The capability goes while the process lives, so only the window
            // names the region and only the address-space teardown can disown it.
            _ = ipc.pointee.releaseCapability(region.handle, of: caller)
            #expect(shared.pointee.owner != nil)

            try? manager.pointee.releaseAddressSpace(caller)
            ipc.pointee.releaseCapabilities(of: caller)

            #expect(charged(caller) == 0)
            #expect(shared.pointee.owner == nil)
            #expect(ram.ppm.pointee.refCount(of: shared.pointee.physicalPage.address) > 0)

            Arch.CPU.setCurrentProcess(0)
            manager.pointee.releaseProcess(caller)
        }
    }


    @Test("a region that escapes its creator still has a budget to answer to")
    func escapedRegionOutlivesItsCreatorSafely() {
        withRegionCaller { ram, heap, manager, ipc, caller, context in
            guard let vma    = caller.pointee.addressSpace.vmaManager,
                  let region = createRegion(pages: 4, context)
            else { return }

            guard let capability = caller.pointee.metadata.pointee.capsTable.resolve(region.handle),
                  case .shared(let shared) = capability.target
            else {
                Issue.record("the region capability did not name a region")
                return
            }

            guard let keeper = try? manager.pointee.spawnProcess(),
                  case .success(let kept) = ipc.pointee.transferCapability(
                    from   : caller,
                    handler: region.handle,
                    to     : keeper,
                    rights : [.read, .write]
                  )
            else {
                Issue.record("could not hand the region to the keeper")
                return
            }

            // The creator lets go of both of its own references while alive, so
            // its teardown has nothing left to find.
            _ = ipc.pointee.releaseCapability(region.handle, of: caller)
            #expect((try? vma.pointee.munmapRegion(
                addr: region.address,
                size : Self.page * 4
            )) == .completed)

            try? manager.pointee.releaseAddressSpace(caller)
            ipc.pointee.releaseCapabilities(of: caller)

            #expect(shared.pointee.owner != nil)

            let regionPhysical = shared.pointee.physicalPage.address
            let cell           = budget(of: caller)

            Arch.CPU.setCurrentProcess(0)
            manager.pointee.releaseProcess(caller)

            // The cell is still the region's, so the heap must not hand it out.
            // Without the region's hold it is the next block of its class.
            let fresh = heap.pointee.kmallocOrNil(FrameBudget.self)
            #expect(fresh != cell)
            if let fresh { heap.pointee.kfree(fresh) }

            // The refund therefore writes somewhere that is still the kernel's.
            let frames = ram.ppm.pointee.allocatedPages
            _ = ipc.pointee.releaseCapability(kept, of: keeper)

            #expect(ram.ppm.pointee.refCount(of: regionPhysical) == 0)
            #expect(ram.ppm.pointee.allocatedPages <= frames - 4)
        }
    }


    @Test("a DMA buffer is charged and disowned like an SHM region")
    func dmaBufferFollowsTheSameRule() {
        withRegionCaller { _, _, _, ipc, caller, context in
            let device = caller.pointee.metadata.pointee.capsTable.install(
                Capability(
                    target: .device(DeviceRegion(address: 0x0900_0000, size: 4096)),
                    badge : Badge(0),
                    rights: [.read, .write, .dma]
                )
            )
            guard let device else {
                Issue.record("could not install the device capability")
                return
            }

            let before = charged(caller)

            guard let buffer = createRegion(pages: 4, context, device: device) else { return }

            let held = charged(caller)
            #expect(held >= before + 4)

            // The capability goes, the window stays, and so does the charge.
            _ = ipc.pointee.releaseCapability(buffer.handle, of: caller)
            #expect(charged(caller) == held)

            guard let vma = caller.pointee.addressSpace.vmaManager else { return }

            #expect((try? vma.pointee.munmapRegion(
                addr: buffer.address,
                size : Self.page * 4
            )) == .completed)

            #expect(charged(caller) == before)
        }
    }


    // MARK: - Failure in the middle

    @Test("a fault that fails after its charge leaves the charge where it was")
    func faultFailingMidwayRefunds() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma     = process.pointee.addressSpace.vmaManager,
                  let address = try? vma.pointee.mmapAnonymous(
                    size       : Self.page,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not build the fixture")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: process)))
            defer { Arch.CPU.setCurrentProcess(0) }

            let before   = charged(process)
            let snapshot = ram.pmmStateSnapshot()

            // The data frame is served and the table under it is not, which is
            // the one shape that charges twice before failing.
            PPMFaultInjection.failAllocationsAfter = 1
            defer { PPMFaultInjection.failAllocationsAfter = nil }

            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .write
            ) == .outOfMemory)

            PPMFaultInjection.failAllocationsAfter = nil

            #expect(charged(process) == before)
            #expect(ram.pmmStateSnapshot() == snapshot)
        }
    }


    // MARK: - Fork

    @Test("a clone charges the child for what it keeps, and gives it back")
    func cloneChargesTheChild() {
        withProcessManager(pages: 224) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let parent    = try? manager.pointee.spawnProcess(),
                  let parentVMA = parent.pointee.addressSpace.vmaManager,
                  let address   = try? parentVMA.pointee.mmapAnonymous(
                    size       : Self.page,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not build the fork fixture")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))
            defer { Arch.CPU.setCurrentProcess(0) }

            #expect(parentVMA.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .write
            ) == .handled)

            let parentCharge = charged(parent)

            var frame = Arch.TrapFrame()
            SplitProcessSyscall.handle(frame: &frame, context: SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))

            guard frame.x0 != UInt64.max,
                  let child    = parent.pointee.family.findChild(id: frame.x0),
                  let childVMA = child.pointee.addressSpace.vmaManager
            else {
                Issue.record("split did not publish its child")
                return
            }

            // The shared page is a claim the child makes too, so it pays for it
            // alongside the tables its own walk needed.
            let childCharge = charged(child)
            #expect(childCharge >= 2)
            #expect(charged(parent) == parentCharge)

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: child)))

            #expect(childVMA.pointee.handlePageFault(
                at    : address,
                cause : .permission,
                access: .write
            ) == .handled)

            // A private copy replaces a shared reference: one page taken, one
            // given back.
            #expect(charged(child) == childCharge)

            let heldBeforeTeardown = ram.ppm.pointee.allocatedPages

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))
            try? manager.pointee.releaseAddressSpace(child)

            #expect(charged(child) == 0)
            #expect(ram.ppm.pointee.allocatedPages < heldBeforeTeardown)
        }
    }


    @Test("the child pays one page per reference the clone keeps")
    func clonePaysPerReference() {
        withProcessManager(pages: 320) { ram, heap, manager in
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

            // Two parents differing only in how many pages are resident. The
            // clone's tables are the same, so the difference is the references.
            func childCharge(residentPages: Int) -> UInt32? {
                guard let parent    = try? manager.pointee.spawnProcess(),
                      let parentVMA = parent.pointee.addressSpace.vmaManager,
                      let address   = try? parentVMA.pointee.mmapAnonymous(
                        size       : Self.page * 4,
                        permissions: [.read, .write, .user]
                      )
                else {
                    Issue.record("could not build a clone parent")
                    return nil
                }

                Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))

                for index in 0..<residentPages {
                    guard parentVMA.pointee.handlePageFault(
                        at    : address + UInt64(index) * Self.page,
                        cause : .translation,
                        access: .write
                    ) == .handled else {
                        Issue.record("a parent page did not become resident")
                        return nil
                    }
                }

                var frame = Arch.TrapFrame()
                SplitProcessSyscall.handle(frame: &frame, context: context)

                guard frame.x0 != UInt64.max,
                      let child = parent.pointee.family.findChild(id: frame.x0)
                else {
                    Issue.record("split did not publish its child")
                    return nil
                }

                return charged(child)
            }

            guard let one   = childCharge(residentPages: 1),
                  let three = childCharge(residentPages: 3)
            else { return }

            Arch.CPU.setCurrentProcess(0)

            #expect(three == one + 2)
        }
    }


    @Test("a child cannot be given more than its creator may hold")
    func childLimitIsClamped() {
        withProcessManager(pages: 160) { _, _, manager in
            guard let parent = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the parent")
                return
            }

            setLimit(64, on: parent)

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))
            defer { Arch.CPU.setCurrentProcess(0) }

            guard let greedy = try? manager.pointee.spawnProcess(frameLimit: 4096),
                  let modest = try? manager.pointee.spawnProcess(frameLimit: 16),
                  let heir   = try? manager.pointee.spawnProcess()
            else {
                Issue.record("could not spawn the children")
                return
            }

            #expect(limit(greedy) == 64)
            #expect(limit(modest) == 16)
            #expect(limit(heir)   == 64)

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: modest)))

            guard let grandchild = try? manager.pointee.spawnProcess(frameLimit: 4096) else {
                Issue.record("could not spawn the grandchild")
                return
            }

            #expect(limit(grandchild) == 16)
        }
    }


    // MARK: - The progress reserve

    @Test("the reserve is spendable by the kernel alone, and only down to zero")
    func progressReserveIsKernelOnly() {
        withHostRAM(pages: 32) { ram in
            #expect(ram.donateAll())
            ram.installLiveManager(reservePages: 4)

            // Every unflagged frame the machine will part with. The last one
            // served leaves the reserve plus the frame it would have taken.
            while (try? ram.ppm.pointee.alloc(4096)) != nil { }

            #expect(ram.ppm.pointee.freePages == 5)

            let snapshot = ram.pmmStateSnapshot()
            #expect(refusedAsOutOfMemory { _ = try ram.ppm.pointee.alloc(4096) })
            #expect(ram.pmmStateSnapshot() == snapshot)

            // The kernel's own allocations are what the reserve is for, and it
            // may spend it down to nothing.
            for _ in 0..<5 {
                guard (try? ram.ppm.pointee.alloc(4096, flag: .kernel)) != nil else {
                    Issue.record("the kernel could not spend its own reserve")
                    return
                }
            }

            #expect(ram.ppm.pointee.freePages == 0)
            #expect(refusedAsOutOfMemory {
                _ = try ram.ppm.pointee.alloc(4096, flag: .kernel)
            })
        }
    }


    // MARK: - The VMA node ceiling

    @Test("the region past the ceiling is refused before a node is allocated")
    func regionCountIsBounded() {
        withProcessManager(pages: 160) { ram, heap, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma     = process.pointee.addressSpace.vmaManager
            else {
                Issue.record("could not spawn the process under test")
                return
            }

            // Its own list, with a ceiling small enough to reach by hand. The
            // regions are spaced so no two of them ever merge.
            let limit: UInt16 = 4
            vma.pointee = VMAManager(
                heap             : heap,
                vmm              : ram.vmm,
                ppm              : ram.ppm,
                rootTablePhysical: process.pointee.addressSpace.rootTablePhysical,
                budget           : budget(of: process),
                nodeLimit        : limit
            )

            // Spaced so no two of them ever merge, and the first one wide
            // enough that a range inside it needs a split.
            let base  = UserSpaceLayout.elfBaseTypical
            let stride = Self.page * 8

            for index in 0..<Int(limit) {
                #expect((try? vma.pointee.registerRegion(
                    start      : base + UInt64(index) * stride,
                    size       : index == 0 ? Self.page * 4 : Self.page,
                    permissions: [.read, .write, .user],
                    backing    : .anonymous,
                    flags      : .noReserve,
                    memoryType : .normal
                )) != nil)
            }

            #expect(vma.pointee.registeredRegions == limit)

            let liveBefore = heap.pointee.metricsLiveBytes
            let snapshot   = ram.pmmStateSnapshot()

            #expect(refusedAsRegionLimit {
                try vma.pointee.registerRegion(
                    start      : base + UInt64(limit) * stride,
                    size       : Self.page,
                    permissions: [.read, .write, .user],
                    backing    : .anonymous,
                    flags      : .noReserve,
                    memoryType : .normal
                )
            })

            #expect(heap.pointee.metricsLiveBytes == liveBefore)
            #expect(ram.pmmStateSnapshot() == snapshot)
            #expect(vma.pointee.registeredRegions == limit)

            // And a split, which is the other way a node is born: the middle of
            // the first region cannot be unmapped without one.
            #expect(refusedAsRegionLimit {
                _ = try vma.pointee.munmapRegion(
                    addr: base + Self.page,
                    size: Self.page
                )
            })

            #expect(vma.pointee.registeredRegions == limit)
            #expect(heap.pointee.metricsLiveBytes == liveBefore)
        }
    }
}
}
