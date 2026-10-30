//
//  DmaQuarantineTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Where a published DMA buffer goes when nobody holds it any more, and what
/// brings it back.
///
/// A device may still write to an address its dead driver gave it, so such a
/// buffer cannot go back to the PPM with its last reference. It used to stay out
/// for the rest of the boot and be counted nowhere, which made every restart of
/// the disk driver a four-page leak. These tests pin the ledger that replaced
/// that, and the one door out of it: a `.dma` holder of the same device saying
/// the device has been reset.
///
/// `.serialized`, and the run needs `--no-parallel`: `DmaQuarantine` is global,
/// like `ProcessStatsIndex`, and the fixture resets both.
extension KernelPolicyTestRoot {
@Suite("DMA quarantine", .serialized)
struct DmaQuarantineTests {

    private static let page = UserSpaceLayout.pageSize

    /// Two transports of one bus, a slot apart, as the virtio bus carves them.
    private static let disk : PhysicalAddress = 0x0a00_0000
    private static let other: PhysicalAddress = 0x0a00_0200

    private typealias Buffer = (
        handle  : UInt32,
        address : VirtualAddress,
        region  : UnsafeMutablePointer<SharedRegion>,
        physical: PhysicalAddress
    )


    // MARK: - Fixture

    private func withWorld(
        pages : Int = 192,
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


    /// A window over `device` in `process`, carrying `rights`.
    private func window(
        _ device  : PhysicalAddress,
        rights    : CapRights = [.read, .write, .dma],
        in process: UnsafeMutablePointer<Process>
    ) -> UInt32? {
        process.pointee.metadata.pointee.capsTable.install(
            Capability(
                target: .device(DeviceRegion(address: device, size: 0x200)),
                badge : Badge(0),
                rights: rights
            )
        )
    }


    /// `dmaAlloc(pages, window)` as `process`, then `dmaPhysical` unless told
    /// not to publish.
    private func buffer(
        pages     : UInt64,
        through window: UInt32,
        as process: UnsafeMutablePointer<Process>,
        publish   : Bool = true,
        _ context : SyscallContext
    ) -> Buffer? {
        var request = Arch.TrapFrame()
        request.x0 = pages
        request.x1 = UInt64(window)
        withCurrentProcess(process) { DmaAlloc.handle(frame: &request, context: context) }

        guard request.x0 != UInt64.max,
              let capability = process.pointee.metadata.pointee.capsTable.resolve(
                  UInt32(truncatingIfNeeded: request.x0)
              ),
              case .dma(let region) = capability.target
        else {
            Issue.record("could not mint the DMA buffer")
            return nil
        }

        let handle = UInt32(truncatingIfNeeded: request.x0)

        if publish {
            var query = Arch.TrapFrame()
            query.x0 = UInt64(handle)
            withCurrentProcess(process) { DmaPhysical.handle(frame: &query, context: context) }
            #expect(query.x0 == region.pointee.physicalAddress(ofPage: 0))
        }

        return (handle, request.x1, region, region.pointee.physicalAddress(ofPage: 0))
    }


    /// `dmaReclaim(handle)` as `process`, answering `x0`.
    private func reclaim(
        _ handle  : UInt64,
        as process: UnsafeMutablePointer<Process>,
        _ context : SyscallContext
    ) -> UInt64 {
        var frame = Arch.TrapFrame()
        frame.x0 = handle
        withCurrentProcess(process) { DmaReclaim.handle(frame: &frame, context: context) }
        return frame.x0
    }


    /// Drops `process`'s capability on `buffer` and its window, in that order.
    private func drop(
        _ buffer  : Buffer,
        pages     : UInt64,
        of process: UnsafeMutablePointer<Process>,
        _ ipc     : UnsafeMutablePointer<KernelIPC>
    ) {
        _ = ipc.pointee.releaseCapability(buffer.handle, of: process)

        #expect((try? process.pointee.addressSpace.vmaManager?.pointee.munmapRegion(
            addr: buffer.address,
            size: Self.page * pages
        )) == .completed)
    }


    /// A buffer published, dropped and reclaimed, so the slabs and tables the
    /// first one pulls in are already there when a test takes its baseline.
    private func prime(
        _ process: UnsafeMutablePointer<Process>,
        through window: UInt32,
        _ ipc    : UnsafeMutablePointer<KernelIPC>,
        _ context: SyscallContext
    ) {
        guard let primed = buffer(pages: 4, through: window, as: process, context) else { return }

        drop(primed, pages: 4, of: process, ipc)
        #expect(reclaim(UInt64(window), as: process, context) == 4)
    }


    /// The whole death of a process: its capabilities, its address space, its cell.
    private func tearDown(
        _ process: UnsafeMutablePointer<Process>,
        _ manager: UnsafeMutablePointer<ProcessManager>,
        _ ipc    : UnsafeMutablePointer<KernelIPC>
    ) {
        ipc.pointee.releaseCapabilities(of: process)
        try? manager.pointee.releaseAddressSpace(process)
        manager.pointee.releaseProcess(process)
    }


    // MARK: - The ledger

    @Test("a published buffer whose last holder goes lands in the ledger, frames and all")
    func publishedBufferIsQuarantined() {
        withWorld { ram, heap, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  let held   = buffer(pages: 5, through: device, as: driver, context)
            else { return }

            drop(held, pages: 5, of: driver, ipc)

            // Five pages are one block of eight, and all eight stay out.
            #expect(held.region.pointee.extent(0).order == 3)
            #expect(ram.ppm.pointee.refCount(of: held.physical) == 1)
            #expect(DmaQuarantine.pages   == 8)
            #expect(DmaQuarantine.regions == 1)

            let stats = ProcStatsSyscall.systemSnapshot(ppm: ram.ppm, heap: heap)
            #expect((stats.availability & SystemMetricAvailability.physicalMemory) != 0)
            #expect(stats.physicalQuarantinedPages   == 8)
            #expect(stats.physicalQuarantinedRegions == 1)
        }
    }


    @Test("an unpublished buffer goes straight back to the PPM")
    func unpublishedBufferIsFreed() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver)
            else { return }

            prime(driver, through: device, ipc, context)

            let baseline = ram.ppm.pointee.allocatedPages

            guard let held = buffer(pages: 4, through: device, as: driver, publish: false, context)
            else { return }

            drop(held, pages: 4, of: driver, ipc)

            #expect(ram.ppm.pointee.refCount(of: held.physical) == 0)
            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(DmaQuarantine.pages   == 0)
            #expect(DmaQuarantine.regions == 0)
        }
    }


    // MARK: - Reclaim

    @Test("a reclaim frees exactly the quarantined buffers of its own device")
    func reclaimFreesOneDevice() {
        withWorld { ram, heap, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let disk   = window(Self.disk, in: driver),
                  let other  = window(Self.other, in: driver)
            else { return }

            prime(driver, through: disk, ipc, context)

            let baseline = ram.ppm.pointee.allocatedPages
            let live     = heap.pointee.metricsLiveBytes

            guard let first  = buffer(pages: 4, through: disk,  as: driver, context),
                  let second = buffer(pages: 2, through: other, as: driver, context),
                  let third  = buffer(pages: 1, through: disk,  as: driver, context)
            else { return }

            drop(first,  pages: 4, of: driver, ipc)
            drop(second, pages: 2, of: driver, ipc)
            drop(third,  pages: 1, of: driver, ipc)

            #expect(DmaQuarantine.pages   == 7)
            #expect(DmaQuarantine.regions == 3)

            #expect(reclaim(UInt64(disk), as: driver, context) == 5)

            #expect(ram.ppm.pointee.refCount(of: first.physical)  == 0)
            #expect(ram.ppm.pointee.refCount(of: third.physical)  == 0)
            #expect(ram.ppm.pointee.refCount(of: second.physical) == 1)
            #expect(DmaQuarantine.pages   == 2)
            #expect(DmaQuarantine.regions == 1)

            // Twice is nothing the second time: the list no longer has them.
            #expect(reclaim(UInt64(disk), as: driver, context) == 0)

            #expect(reclaim(UInt64(other), as: driver, context) == 2)

            #expect(DmaQuarantine.pages   == 0)
            #expect(DmaQuarantine.regions == 0)
            #expect(ram.ppm.pointee.allocatedPages == baseline)
            #expect(heap.pointee.metricsLiveBytes == live)

            let stats = ProcStatsSyscall.systemSnapshot(ppm: ram.ppm, heap: heap)
            #expect(stats.physicalQuarantinedPages   == 0)
            #expect(stats.physicalQuarantinedRegions == 0)
        }
    }


    /// The ordering the driver depends on: it allocates and publishes its own
    /// buffer, resets the device, and only then reclaims.
    @Test("a reclaim never frees a buffer somebody still holds, published or not")
    func reclaimSparesLiveBuffers() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  let dead   = buffer(pages: 4, through: device, as: driver, context),
                  let mapped = buffer(pages: 2, through: device, as: driver, context),
                  let fresh  = buffer(pages: 1, through: device, as: driver, context),
                  let quiet  = buffer(pages: 1, through: device, as: driver, publish: false, context)
            else { return }

            drop(dead, pages: 4, of: driver, ipc)

            // Its capability gone, its window still there: one holder left.
            _ = ipc.pointee.releaseCapability(mapped.handle, of: driver)
            #expect(mapped.region.pointee.references == 1)

            #expect(reclaim(UInt64(device), as: driver, context) == 4)

            #expect(ram.ppm.pointee.refCount(of: dead.physical) == 0)

            for held in [mapped, fresh, quiet] {
                #expect(ram.ppm.pointee.refCount(of: held.physical) == 1)
            }
            #expect(mapped.region.pointee.deviceVisible == true)
            #expect(fresh.region.pointee.deviceVisible == true)
            #expect(fresh.region.pointee.references == 2)

            // The survivor still dies into the ledger when its window goes.
            #expect((try? driver.pointee.addressSpace.vmaManager?.pointee.munmapRegion(
                addr: mapped.address,
                size: Self.page * 2
            )) == .completed)

            #expect(DmaQuarantine.pages   == 2)
            #expect(DmaQuarantine.regions == 1)
            #expect(ram.ppm.pointee.refCount(of: mapped.physical) == 1)
        }
    }


    @Test("a reclaim needs a device window that carries DMA")
    func reclaimIsGated() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            drop(dead, pages: 4, of: driver, ipc)

            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            guard let noDMA = window(Self.disk, rights: [.read, .write, .grant], in: driver),
                  let notADevice = driver.pointee.metadata.pointee.capsTable.install(
                      Capability(target: .endpoint(endpoint), badge: Badge(0), rights: [.send])
                  ),
                  let stale = window(Self.disk, in: driver)
            else {
                Issue.record("could not install the refused handles")
                return
            }

            _ = ipc.pointee.releaseCapability(stale, of: driver)

            let refused: [UInt64] = [
                UInt64(noDMA),
                UInt64(notADevice),
                UInt64(stale),
                (UInt64(1) << 32) | UInt64(device),
            ]

            for handle in refused {
                #expect(reclaim(handle, as: driver, context) == UInt64.max)
            }

            #expect(ram.ppm.pointee.refCount(of: dead.physical) == 1)
            #expect(DmaQuarantine.pages   == 4)
            #expect(DmaQuarantine.regions == 1)
        }
    }


    @Test("a block the PPM refuses is left out of the answer, and its region still leaves the list")
    func refusedBlockIsNotCounted() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            drop(dead, pages: 4, of: driver, ipc)

            // Freed behind the ledger's back, so the reclaim's own free is refused.
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)

            #expect(reclaim(UInt64(device), as: driver, context) == 0)
            #expect(DmaQuarantine.pages   == 0)
            #expect(DmaQuarantine.regions == 0)

            // And said, as the last thing the kernel logged.
            var last: LogRing.Record? = nil
            LogRing.forEachRecord { last = $0 }

            guard let record = last else {
                Issue.record("the refusal was not logged")
                return
            }

            let payload = (0..<record.payloadLength).map { LogRing.payloadByte(record, $0) }

            #expect(record.level == LogLevel.error.rawValue)
            #expect(String(decoding: payload, as: UTF8.self).hasPrefix(
                "quarantined DMA region released after a reset but one of its frames was refused"
            ))
        }
    }


    // MARK: - The creator's charge

    /// The charge lasts as long as the frames are out of the PPM: a buffer that
    /// died onto the ledger is still its creator's, until the reclaim.
    @Test("a creator that lives on pays for its quarantined buffer until the reclaim")
    func livingCreatorPaysUntilTheReclaim() {
        withWorld { _, _, manager, ipc, context in
            // The keeper stays alive, so the tables under the windows below
            // already exist and every charge measured here is a block's alone.
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  buffer(pages: 1, through: device, as: driver, publish: false, context) != nil
            else { return }

            let budget: UnsafeMutablePointer<FrameBudget> = driver.pointee.metadata.pointee.budget
            let before = budget.pointee.charged
            let holds  = budget.pointee.references

            // Never published: its death refunds at once, as it always did.
            guard let quiet = buffer(pages: 7, through: device, as: driver, publish: false, context)
            else { return }

            #expect(budget.pointee.charged == before + 8)
            drop(quiet, pages: 7, of: driver, ipc)
            #expect(budget.pointee.charged == before)
            #expect(budget.pointee.references == holds)

            // Published: its death takes it to the ledger, charge and hold with it.
            guard let dead = buffer(pages: 7, through: device, as: driver, context) else { return }

            drop(dead, pages: 7, of: driver, ipc)
            #expect(DmaQuarantine.pages == 8)
            #expect(budget.pointee.charged == before + 8)
            #expect(budget.pointee.references == holds + 1)

            #expect(reclaim(UInt64(device), as: driver, context) == 8)
            #expect(budget.pointee.charged == before)
            #expect(budget.pointee.references == holds)
        }
    }


    /// The quarantined buffer is the last thing holding a dead creator's budget,
    /// so the reclaim that refunds it is also what frees it.
    @Test("a creator that dies before the reclaim leaves nothing behind once it comes")
    func deadCreatorLeavesNothing() {
        withWorld(pages: 256) { ram, heap, manager, ipc, context in
            guard let bus      = try? manager.pointee.spawnProcess(),
                  let resetter = window(Self.disk, in: bus)
            else { return }

            // Twice: the first round pulls in the slabs, the second is measured.
            for round in 0..<2 {
                let pages = ram.ppm.pointee.allocatedPages
                let live  = heap.pointee.metricsLiveBytes

                guard let driver = try? manager.pointee.spawnProcess(),
                      let device = window(Self.disk, in: driver),
                      let dead   = buffer(pages: 4, through: device, as: driver, context)
                else { return }

                let budget: UnsafeMutablePointer<FrameBudget> = driver.pointee.metadata.pointee.budget

                drop(dead, pages: 4, of: driver, ipc)
                tearDown(driver, manager, ipc)

                // The process is gone and its budget is not: the ledger holds it.
                #expect(budget.pointee.references == 1)
                #expect(budget.pointee.charged >= 4)

                #expect(reclaim(UInt64(resetter), as: bus, context) == 4)
                #expect(DmaQuarantine.regions == 0)

                if round == 1 {
                    #expect(ram.ppm.pointee.allocatedPages == pages)
                    #expect(heap.pointee.metricsLiveBytes == live)
                }
            }
        }
    }


    // MARK: - The leak this closes

    /// Every restart used to leave its buffer behind for good. Now each new
    /// driver gives back the one before it, so the machine holds the same frames
    /// after every restart instead of four more.
    @Test("a driver restarted over and over holds steady once each one reclaims")
    func restartsDoNotLeak() {
        withWorld(pages: 256) { ram, _, manager, ipc, context in
            var steady: UInt64? = nil

            for round in 0..<5 {
                guard let driver = try? manager.pointee.spawnProcess(),
                      let device = window(Self.disk, in: driver),
                      buffer(pages: 4, through: device, as: driver, context) != nil
                else { return }

                // After its own reset: the predecessor's buffer, never its own.
                #expect(reclaim(UInt64(device), as: driver, context) == (round == 0 ? 0 : 4))
                #expect(DmaQuarantine.pages == 0)

                // Measured from the second round, once the slabs are in place.
                if let steady {
                    #expect(ram.ppm.pointee.allocatedPages == steady)
                } else if round == 1 {
                    steady = ram.ppm.pointee.allocatedPages
                }

                tearDown(driver, manager, ipc)

                #expect(DmaQuarantine.pages   == 4)
                #expect(DmaQuarantine.regions == 1)
            }

            // The last one's buffer goes back too, once somebody resets the device.
            guard let bus    = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: bus)
            else { return }

            #expect(reclaim(UInt64(device), as: bus, context) == 4)
            #expect(DmaQuarantine.pages   == 0)
            #expect(DmaQuarantine.regions == 0)
        }
    }
}
}
