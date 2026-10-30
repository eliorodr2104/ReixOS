//
//  SharedRegionLifetimeTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Who holds a shared region, and what happens as each of them lets go.
///
/// `SharedRegion.references` is the only thing standing between a live window
/// and a freed frame, so the invariant is worth stating as an equation rather
/// than as a feeling: it equals the number of holders this suite can enumerate,
/// which is capabilities in tables, plus windows in address spaces, plus
/// capabilities parked on an endpoint waiting to be delivered.
///
/// The in-flight half is new. A parked message used to hold the sender's *slot
/// number* and resolve it whenever a receiver turned up, so the slot could be
/// dropped, reused, or torn down with the sender in between. Four of the tests
/// below are that story.
///
/// `.serialized`, and the run needs `--no-parallel`, for `ForkSpawnTests`'
/// reason: `PPMBackend.physicalOffset` and `ProcessStatsIndex` are global.
extension KernelPolicyTestRoot {
@Suite("Shared region lifetime", .serialized)
struct SharedRegionLifetimeTests {

    private static let page = UserSpaceLayout.pageSize

    private typealias Region = UnsafeMutablePointer<SharedRegion>


    // MARK: - Counting the holders by hand

    /// Capabilities in `process`'s table that name `region`.
    private func capabilities(
        naming region: Region,
        in   process : UnsafeMutablePointer<Process>
    ) -> Int {
        guard let metadata = process.pointee.metadata else { return 0 }

        var found = 0
        for slot in 0..<metadata.pointee.capsTable.caps.count {
            guard let capability = metadata.pointee.capsTable.caps[slot] else { continue }

            switch capability.target {
                case .shared(let held), .dma(let held):
                    if held == region { found += 1 }

                default: break
            }
        }

        return found
    }


    /// Windows in `process`'s address space that name `region`.
    private func windows(
        naming region: Region,
        in   process : UnsafeMutablePointer<Process>
    ) -> Int {
        guard let manager = process.pointee.addressSpace.vmaManager else { return 0 }

        var found = 0
        var node  = manager.pointee.vmaList.head

        while let current = node {
            if current.pointee.sharedRegion == region { found += 1 }
            node = current.pointee.next
        }

        return found
    }


    /// Capabilities parked on an endpoint inside `process`'s pending message.
    private func inFlight(
        naming region: Region,
        in   process : UnsafeMutablePointer<Process>
    ) -> Int {
        guard let held = process.pointee.pending?.grant else { return 0 }

        switch held.target {
            case .shared(let named), .dma(let named): return named == region ? 1 : 0
            default                                 : return 0
        }
    }


    /// Every holder of `region` across `processes`.
    private func holders(
        of region: Region,
        across processes: [UnsafeMutablePointer<Process>]
    ) -> Int {
        processes.reduce(0) { total, process in
            total
                + capabilities(naming: region, in: process)
                + windows(naming: region, in: process)
                + inFlight(naming: region, in: process)
        }
    }


    // MARK: - Fixture

    private func withWorld(
        _ body: (
            HostRAM,
            UnsafeMutablePointer<KernelHeap>,
            UnsafeMutablePointer<ProcessManager>,
            UnsafeMutablePointer<KernelIPC>,
            UnsafeMutablePointer<Endpoint>,
            SyscallContext
        ) -> Void
    ) {
        withProcessManager(pages: 256) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            // One reference for the allocation itself: this endpoint did not
            // come out of the kernel heap, so `kfree` must never see it.
            endpoint.pointee.references = 1

            body(ram, heap, manager, ipc, endpoint, SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))
        }
    }


    /// `shmCreate(pages)` as `process`, with its handle, window and region.
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
            Issue.record("shmCreate refused a region the fixture needs")
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


    /// Installs an endpoint capability and retains it, the way every real
    /// install does, so the endpoint's receiver count stays honest.
    @discardableResult
    private func give(
        _ ipc      : UnsafeMutablePointer<KernelIPC>,
        _ process  : UnsafeMutablePointer<Process>,
        on endpoint: UnsafeMutablePointer<Endpoint>,
        _ rights   : CapRights
    ) -> (handle: UInt32, capability: Capability) {

        let capability = Capability(
            target: .endpoint(endpoint),
            badge : Badge(0),
            rights: rights
        )

        let handle = process.pointee.metadata.pointee.capsTable.install(capability)!
        ipc.pointee.retain(capability)

        return (handle, capability)
    }


    /// A send frame whose packed grant word names `handle` with `rights`.
    private func frame(granting handle: UInt32?, _ rights: CapRights) -> Arch.TrapFrame {
        var trap = Arch.TrapFrame()
        trap.x1 = (UInt64(1) << 8) | 1
        trap.x2 = 42
        trap.x6 = handle.map { UInt64($0) | (UInt64(rights.rawValue) << 32) }
            ?? UInt64(UInt32.max)

        return trap
    }


    private func charged(_ process: UnsafeMutablePointer<Process>) -> UInt32 {
        process.pointee.metadata.pointee.budget.pointee.charged
    }


    // MARK: - The invariant, step by step

    @Test("references equals the holders that can be counted, at every step")
    func referencesMatchTheHolders() {
        withWorld { ram, _, manager, ipc, _, context in
            guard let creator  = try? manager.pointee.spawnProcess(),
                  let receiver = try? manager.pointee.spawnProcess(),
                  let created  = create(pages: 2, as: creator, context)
            else { return }

            let region  = created.region
            let world   = [creator, receiver]
            let frames  = ram.ppm.pointee.allocatedPages
            let paidFor = charged(creator)

            // One capability and one window, both the creator's.
            #expect(region.pointee.references == 2)
            #expect(holders(of: region, across: world) == 2)

            // The receiver takes a capability of its own.
            #expect({
                if case .success = ipc.pointee.transferCapability(
                    from: creator, handler: created.handle,
                    to  : receiver, rights: [.read, .write, .grant]
                ) { return true } else { return false }
            }())

            #expect(region.pointee.references == 3)
            #expect(holders(of: region, across: world) == 3)

            // And a window of its own, which is what `shmMap` opens.
            guard let receiverVMA = receiver.pointee.addressSpace.vmaManager,
                  let receiverWindow = try? receiverVMA.pointee.mapRegion(
                    region,
                    kind       : .shared,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("the receiver could not map the region")
                return
            }

            #expect(region.pointee.references == 4)
            #expect(holders(of: region, across: world) == 4)

            // The creator drops its capability and keeps its window: the
            // documented contract, and the frames are still its own to pay for.
            _ = ipc.pointee.releaseCapability(created.handle, of: creator)

            #expect(region.pointee.references == 3)
            #expect(holders(of: region, across: world) == 3)
            #expect(charged(creator) == paidFor)
            #expect(creator.pointee.addressSpace.vmaManager?.pointee
                        .isPageMapped(at: created.address) == true)

            // The creator unmaps. Nothing of its own is left, and the region
            // lives on because the receiver holds both kinds of reference.
            #expect((try? creator.pointee.addressSpace.vmaManager?.pointee.munmapRegion(
                addr: created.address, size: Self.page * 2
            )) == .completed)

            #expect(region.pointee.references == 2)
            #expect(holders(of: region, across: world) == 2)
            #expect(ram.ppm.pointee.refCount(of: region.pointee.physicalAddress(ofPage: 0)) > 0)

            // The charge follows the frames, once: the creator no longer holds
            // any of them.
            #expect(charged(creator) < paidFor)

            // The receiver lets go of its window, then of its capability. The
            // last one to go is what kills the region.
            #expect((try? receiverVMA.pointee.munmapRegion(
                addr: receiverWindow, size: Self.page * 2
            )) == .completed)

            #expect(region.pointee.references == 1)

            ipc.pointee.releaseCapabilities(of: receiver)

            #expect(ram.ppm.pointee.allocatedPages <= frames)
        }
    }


    @Test("a clone gives the child's window a reference of its own")
    func cloneTakesAReference() {
        withWorld { ram, _, manager, ipc, _, context in
            guard let parent = try? manager.pointee.spawnProcess(),
                  let child  = try? manager.pointee.spawnProcess(),
                  let parentVMA = parent.pointee.addressSpace.vmaManager,
                  let childVMA  = child.pointee.addressSpace.vmaManager,
                  let created   = create(pages: 1, as: parent, context)
            else { return }

            let region = created.region

            #expect(region.pointee.references == 2)

            do { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            catch { Issue.record("clone failed: \(error)"); return }

            // A holder like any other. Without it the parent's exit would free
            // frames the child still maps.
            #expect(windows(naming: region, in: child) == 1)
            #expect(region.pointee.references == 3)
            #expect(holders(of: region, across: [parent, child]) == 3)

            // The parent goes entirely. The child still maps the frames, so the
            // frames are still there.
            try? manager.pointee.releaseAddressSpace(parent)
            ipc.pointee.releaseCapabilities(of: parent)
            Arch.CPU.setCurrentProcess(0)
            manager.pointee.releaseProcess(parent)

            #expect(region.pointee.references == 1)
            #expect(ram.ppm.pointee.refCount(of: region.pointee.physicalAddress(ofPage: 0)) > 0)
            #expect(childVMA.pointee.isPageMapped(at: created.address))
        }
    }


    // MARK: - A capability in flight

    /// Parks a blocking send from `sender` carrying `granting`, and answers
    /// whether it really parked.
    private func park(
        _ ipc     : UnsafeMutablePointer<KernelIPC>,
        _ sender  : UnsafeMutablePointer<Process>,
        _ send    : Capability,
        granting  : UInt32?,
        _ rights  : CapRights = [.read, .write]
    ) -> Bool {
        var parked = false

        withCurrentProcess(sender) {
            if case .success(.blocked) = ipc.pointee.send(
                capability: send,
                frame     : frame(granting: granting, rights)
            ) { parked = true }
        }

        return parked
    }


    /// Collects a parked message as `receiver` and answers the granted handle.
    private func collect(
        _ ipc      : UnsafeMutablePointer<KernelIPC>,
        _ receiver : UnsafeMutablePointer<Process>,
        _ receiving: Capability
    ) -> UInt32? {
        var delivered: UInt32? = nil

        let trap = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        trap.initialize(to: Arch.TrapFrame())
        defer { trap.deinitialize(count: 1); trap.deallocate() }

        withCurrentProcess(receiver) {
            _ = ipc.pointee.receive(capability: receiving, frame: trap)
            delivered = IPCDelivery.grant(of: trap.pointee.x7)
        }

        return delivered
    }


    @Test("a parked send keeps its attachment after the sender drops the slot")
    func parkedSendSurvivesTheSlotGoing() {
        withWorld { _, _, manager, ipc, endpoint, context in
            guard let sender   = try? manager.pointee.spawnProcess(),
                  let receiver = try? manager.pointee.spawnProcess(),
                  let created  = create(pages: 1, as: sender, context)
            else { return }

            let region  = created.region
            let sending = give(ipc, sender, on: endpoint, [.send]).capability
            let taking  = give(ipc, receiver, on: endpoint, [.receive]).capability

            #expect(park(ipc, sender, sending, granting: created.handle))

            // Resolved at send: capability, window, and the one in flight.
            #expect(region.pointee.references == 3)
            #expect(inFlight(naming: region, in: sender) == 1)

            // The sender drops the slot it sent. Nothing about the message
            // changes, because the message never held the slot.
            _ = ipc.pointee.releaseCapability(created.handle, of: sender)

            #expect(region.pointee.references == 2)
            #expect(capabilities(naming: region, in: sender) == 0)
            #expect(inFlight(naming: region, in: sender) == 1)

            guard let handed = collect(ipc, receiver, taking) else {
                Issue.record("the receiver was handed nothing")
                return
            }

            guard let arrived = receiver.pointee.metadata.pointee.capsTable.resolve(handed),
                  case .shared(let named) = arrived.target
            else {
                Issue.record("the delivered capability does not name a region")
                return
            }

            #expect(named == region)
            #expect(arrived.rights == [.read, .write])
            #expect(region.pointee.references == 2)
            #expect(holders(of: region, across: [sender, receiver]) == 2)
        }
    }


    @Test("a slot reused before delivery does not change what was sent")
    func reusingTheSlotDoesNotRewriteTheMessage() {
        withWorld { _, _, manager, ipc, endpoint, context in
            guard let sender   = try? manager.pointee.spawnProcess(),
                  let receiver = try? manager.pointee.spawnProcess(),
                  let first    = create(pages: 1, as: sender, context)
            else { return }

            let sending = give(ipc, sender, on: endpoint, [.send]).capability
            let taking  = give(ipc, receiver, on: endpoint, [.receive]).capability

            #expect(park(ipc, sender, sending, granting: first.handle))

            // `CapsTable` hands out the lowest free slot, so the second region
            // lands on the number the parked message used to name.
            _ = ipc.pointee.releaseCapability(first.handle, of: sender)

            guard let second = create(pages: 1, as: sender, context) else { return }

            #expect(second.handle == first.handle)
            #expect(second.region != first.region)

            guard let handed = collect(ipc, receiver, taking),
                  let arrived = receiver.pointee.metadata.pointee.capsTable.resolve(handed),
                  case .shared(let named) = arrived.target
            else {
                Issue.record("the receiver was handed nothing usable")
                return
            }

            // The first region, which is the one that was sent.
            #expect(named == first.region)
            #expect(named != second.region)
        }
    }


    @Test("a sender that dies parked gives its attachment back")
    func senderDyingParkedReleasesTheAttachment() {
        withWorld { ram, _, manager, ipc, endpoint, context in
            guard let sender   = try? manager.pointee.spawnProcess(),
                  let keeper   = try? manager.pointee.spawnProcess(),
                  let created  = create(pages: 1, as: sender, context)
            else { return }

            let region  = created.region
            let sending = give(ipc, sender, on: endpoint, [.send]).capability
            give(ipc, keeper, on: endpoint, [.receive])

            // Somebody else holds the region too, so its death is attributable
            // to the last holder rather than to the first.
            #expect({
                if case .success = ipc.pointee.transferCapability(
                    from: sender, handler: created.handle,
                    to  : keeper, rights: [.read]
                ) { return true } else { return false }
            }())

            #expect(park(ipc, sender, sending, granting: created.handle))
            #expect(region.pointee.references == 4)

            let physical = region.pointee.physicalAddress(ofPage: 0)

            withCurrentProcess(sender) {
                _ = manager.pointee.killProcess(
                    sender,
                    reason : .exited(0),
                    context: context
                )
            }

            // The sender's capability, its window and the parked attachment are
            // all gone; the keeper's capability is what is left.
            #expect(region.pointee.references == 1)
            #expect(ram.ppm.pointee.refCount(of: physical) > 0)

            ipc.pointee.releaseCapabilities(of: keeper)

            #expect(ram.ppm.pointee.refCount(of: physical) == 0)
        }
    }


    @Test("a receiver that dies before delivery gives the attachment back")
    func receiverDyingBeforeDeliveryReleasesTheAttachment() {
        withWorld { ram, _, manager, ipc, endpoint, context in
            guard let sender   = try? manager.pointee.spawnProcess(),
                  let receiver = try? manager.pointee.spawnProcess(),
                  let created  = create(pages: 1, as: sender, context)
            else { return }

            let region  = created.region
            let sending = give(ipc, sender, on: endpoint, [.send]).capability
            give(ipc, receiver, on: endpoint, [.receive])

            #expect(park(ipc, sender, sending, granting: created.handle))
            #expect(region.pointee.references == 3)

            // The only process that could ever collect it dies. The sender is
            // let go with `peerDied`, and its message with it.
            withCurrentProcess(receiver) {
                _ = manager.pointee.killProcess(
                    receiver,
                    reason : .exited(0),
                    context: context
                )
            }

            #expect(sender.pointee.pending == nil)
            #expect(inFlight(naming: region, in: sender) == 0)
            #expect(region.pointee.references == 2)
            #expect(sender.pointee.context?.pointee.x0 == IPCStatus.peerDied.rawValue)

            // And the sender still has both of its own holds.
            #expect(capabilities(naming: region, in: sender) == 1)
            #expect(windows(naming: region, in: sender) == 1)
            #expect(ram.ppm.pointee.refCount(of: region.pointee.physicalAddress(ofPage: 0)) > 0)
        }
    }


    @Test("a full receiver table refuses the attachment and frees it")
    func aRefusedDeliveryReleasesTheAttachment() {
        withWorld { ram, _, manager, ipc, endpoint, context in
            guard let sender   = try? manager.pointee.spawnProcess(),
                  let receiver = try? manager.pointee.spawnProcess(),
                  let created  = create(pages: 1, as: sender, context)
            else { return }

            let region  = created.region
            let sending = give(ipc, sender, on: endpoint, [.send]).capability
            let taking  = give(ipc, receiver, on: endpoint, [.receive]).capability

            #expect(park(ipc, sender, sending, granting: created.handle))

            // Fill every slot the receiver has left, so the delivery has
            // nowhere to land.
            let table = receiver.pointee.metadata.pointee.capsTable.caps.count
            for _ in 0..<table {
                _ = receiver.pointee.metadata.pointee.capsTable.install(
                    Capability(target: .clock, badge: Badge(0), rights: [.read])
                )
            }

            #expect(collect(ipc, receiver, taking) == nil)

            // Refused, and given back rather than leaked: the sender's own two
            // holds are all that is left.
            #expect(region.pointee.references == 2)
            #expect(sender.pointee.context?.pointee.x0 == IPCStatus.grantRejected.rawValue)
            #expect(ram.ppm.pointee.refCount(of: region.pointee.physicalAddress(ofPage: 0)) > 0)
        }
    }


    // MARK: - The object itself

    @Test("a region's kind and size are fixed when it is made")
    func kindAndSizeAreImmutable() {
        withWorld { _, _, manager, _, _, context in
            guard let caller  = try? manager.pointee.spawnProcess(),
                  let created = create(pages: 3, as: caller, context)
            else { return }

            #expect(created.region.pointee.kind == .shared)
            #expect(created.region.pointee.pageCount == 3)

            // A DMA buffer is the other kind, and `shmMap` will not open a
            // window onto it however the capability is labelled.
            guard let device = caller.pointee.metadata.pointee.capsTable.install(
                Capability(
                    target: .device(DeviceRegion(address: 0x0900_0000, size: 4096)),
                    badge : Badge(0),
                    rights: [.read, .write, .dma]
                )
            ) else {
                Issue.record("could not install the device window")
                return
            }

            let request = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            request.initialize(to: Arch.TrapFrame())
            defer { request.deinitialize(count: 1); request.deallocate() }

            request.pointee.x0 = 1
            request.pointee.x1 = UInt64(device)

            withCurrentProcess(caller) {
                DmaAlloc.handle(frame: request, context: context)
            }

            guard request.pointee.x0 != UInt64.max,
                  let capability = caller.pointee.metadata.pointee.capsTable.resolve(
                      UInt32(truncatingIfNeeded: request.pointee.x0)
                  ),
                  case .dma(let buffer) = capability.target
            else {
                Issue.record("could not mint the DMA buffer")
                return
            }

            #expect(buffer.pointee.kind == .dma)
            #expect(buffer.pointee.pageCount == 1)
        }
    }
}
}
