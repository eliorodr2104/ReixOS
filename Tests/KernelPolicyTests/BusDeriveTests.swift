//
//  BusDeriveTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// What a bus may be narrowed into.
///
/// A bus is the only capability that hands out other capabilities over the same
/// hardware, so every bound it applies is the only bound there is. Hand back one
/// byte past a transport and the window reaches the next machine's registers;
/// round the size up and it reaches its neighbours; forget to intersect the
/// rights and a bus held read-only mints something that writes.
///
/// The bus these tests carve is deliberately awkward, because the machine this
/// runs on is not: its transports are declared out of order, there is a hole
/// between two of them, and its lines do not run in step with its slots. All
/// three were true of the model and none were true of QEMU's `virt`, which is
/// why none of them were caught.
///
/// The interrupt side is tested for its refusals only. Succeeding at it ends in
/// a write to the distributor, and there is no distributor on this host.
@Suite("Bus narrowing", .serialized)
struct BusDeriveTests {

    private static let slot: UInt64 = 0x200

    /// Declared low to high, and given to `include` in none of that order.
    private static let windows: [(base: UInt64, line: UInt32)] = [
        (0x0A00_0000, 48),
        (0x0A00_0400, 51),
        (0x0A00_0A00, 49)
    ]

    /// The byte the hole starts at. In no transport, so no index reaches it.
    private static let hole: UInt64 = 0x0A00_0200


    /// The bus above, built the way a device tree walk builds one: in whatever
    /// order the blob happened to list the nodes.
    private static func busInfo() -> VirtioBusInfo {
        var info = VirtioBusInfo()

        info.include(base: 0x0A00_0400, size: Self.slot, line: 51)
        info.include(base: 0x0A00_0000, size: Self.slot, line: 48)
        info.include(base: 0x0A00_0A00, size: Self.slot, line: 49)

        return info
    }


    private func frame(x0: UInt64 = 0, x1: UInt64 = 0, x2: UInt64 = 0)
    -> UnsafeMutablePointer<Arch.TrapFrame> {

        let pointer = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        pointer.initialize(to: Arch.TrapFrame())
        pointer.pointee.x0 = x0
        pointer.pointee.x1 = x1
        pointer.pointee.x2 = x2

        return pointer
    }


    /// A caller holding one bus, with whatever rights the test wants on it.
    private func withBusHolder(
        rights: CapRights = [.grant, .derive, .read, .write],
        _ body: (UnsafeMutablePointer<Process>, UInt32, SyscallContext) -> Void
    ) {
        withProcessManager(pages: 96) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let caller = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the calling process")
                return
            }

            let bus = UnsafeMutablePointer<BusAuthority>.allocate(capacity: 1)
            bus.initialize(to: BusAuthority(bus: Self.busInfo()))
            defer { bus.deinitialize(count: 1); bus.deallocate() }

            guard let handle = caller.pointee.metadata?.pointee.capsTable.install(
                Capability(target: .bus(bus), badge: Badge(0), rights: rights)
            ) else {
                Issue.record("could not install the bus capability")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: caller)))
            defer { Arch.CPU.setCurrentProcess(0) }

            body(caller, handle, SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))
        }
    }


    private func derived(
        _ process: UnsafeMutablePointer<Process>,
        _ handle : UInt32
    ) -> Capability? {
        process.pointee.metadata?.pointee.capsTable.resolve(handle)
    }


    // MARK: - The list the kernel builds

    /// The regression. `include` used to lower the base of a merged span without
    /// extending its length, so a transport declared before a lower-addressed one
    /// fell off the top of the bus and was never seen again.
    @Test("a transport declared before a lower one is still there afterwards")
    func orderDoesNotMatter() {
        var info = VirtioBusInfo()

        info.include(base: 0x0A00_0A00, size: Self.slot, line: 49)
        info.include(base: 0x0A00_0000, size: Self.slot, line: 48)

        #expect(info.count == 2)
        #expect(info.transport(at: 0)?.base == 0x0A00_0000)
        #expect(info.transport(at: 1)?.base == 0x0A00_0A00)

        // Built the other way round, the same bus.
        var reversed = VirtioBusInfo()

        reversed.include(base: 0x0A00_0000, size: Self.slot, line: 48)
        reversed.include(base: 0x0A00_0A00, size: Self.slot, line: 49)

        #expect(reversed.count == info.count)
        #expect(reversed.transport(at: 0)?.base == info.transport(at: 0)?.base)
        #expect(reversed.transport(at: 1)?.base == info.transport(at: 1)?.base)
    }


    @Test("each transport keeps the line its own node declared")
    func lineBelongsToTheTransport() {
        let info = Self.busInfo()

        #expect(info.count == UInt32(Self.windows.count))

        for (index, window) in Self.windows.enumerated() {
            let transport = info.transport(at: UInt32(index))

            #expect(transport?.base == window.base)
            #expect(transport?.line == window.line)
            #expect(transport?.size == UInt32(Self.slot))
        }

        // Not the first line plus the index, which is what it used to be and
        // what this bus is arranged to disagree with.
        #expect(info.transport(at: 1)?.line != 48 + 1)
        #expect(info.transport(at: 2)?.line != 48 + 2)
    }


    @Test("a transport the bus does not have is nothing")
    func indexIsBoundedInTheList() {
        let info = Self.busInfo()

        #expect(info.transport(at: UInt32(Self.windows.count)) == nil)
        #expect(info.transport(at: UInt32.max) == nil)
        #expect(VirtioBusInfo().transport(at: 0) == nil)
    }


    /// Everything a later reader would otherwise have to trust. A blob is not a
    /// promise: it is whatever was in memory when the machine started.
    @Test("a transport that contradicts one already there is refused")
    func contradictionsAreRefused() {
        var info = Self.busInfo()
        let before = info.count

        // Overlapping the first window, exactly and then partially.
        info.include(base: 0x0A00_0000, size: Self.slot, line: 60)
        info.include(base: 0x0A00_0100, size: Self.slot, line: 61)

        // Somewhere else entirely, but claiming a line already spoken for.
        info.include(base: 0x0B00_0000, size: Self.slot, line: 51)

        // Nonsense a stale or hostile blob can say.
        info.include(base: 0,          size: Self.slot, line: 62)
        info.include(base: 0x0B00_0000, size: 0,        line: 63)
        info.include(base: UInt64.max, size: Self.slot, line: 64)

        #expect(info.count    == before)
        #expect(info.rejected == 6)
    }


    @Test("a bus wider than there is room for keeps what it can and says so")
    func capacityIsBounded() {
        var info = VirtioBusInfo()

        for index in 0...UInt64(VirtioBusInfo.capacity) {
            info.include(
                base: 0x0A00_0000 + index * Self.slot,
                size: Self.slot,
                line: 48 + UInt32(index)
            )
        }

        #expect(info.count    == UInt32(VirtioBusInfo.capacity))
        #expect(info.rejected == 1)
    }


    // MARK: - The extent

    @Test("a slot is carved where the machine said it is, at the size it said")
    func windowIsExact() {
        withBusHolder { caller, bus, context in

            for (index, window) in Self.windows.enumerated() {
                let request = frame(x0: UInt64(bus), x1: UInt64(index))
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveDeviceSyscall.handle(frame: request, context: context)

                let handle = UInt32(truncatingIfNeeded: request.pointee.x0)
                #expect(handle != UInt32.max)

                guard case .device(let carved)? = derived(caller, handle)?.target else {
                    Issue.record("the derived handle does not name a device window")
                    return
                }

                #expect(carved.address == window.base)

                // Not rounded up to a page. Rounding is what would hand over the
                // seven neighbouring slots along with this one.
                #expect(carved.size == Self.slot)
            }
        }
    }


    /// What the merged span gave away. The hole between the second and third
    /// transports belongs to nothing, and there is no index that reaches it,
    /// because the only windows that exist are the ones that were declared.
    @Test("nothing between two transports can be carved out")
    func holesAreNotAuthority() {
        withBusHolder { caller, bus, context in

            var reached: [UInt64] = []

            for index in 0..<UInt64(Self.windows.count) {
                let request = frame(x0: UInt64(bus), x1: index)
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveDeviceSyscall.handle(frame: request, context: context)

                guard case .device(let carved)? = derived(
                    caller,
                    UInt32(truncatingIfNeeded: request.pointee.x0)
                )?.target else {
                    Issue.record("slot \(index) carved nothing")
                    return
                }

                reached.append(carved.address)
            }

            #expect(reached == Self.windows.map(\.base))
            #expect(!reached.contains(Self.hole))
        }
    }


    @Test("a slot past the end of the bus is refused")
    func pastTheEndIsRefused() {
        withBusHolder { _, bus, context in

            let cases: [UInt64] = [
                UInt64(Self.windows.count),      // one past the last
                UInt64(Self.windows.count) + 1,
                UInt64(UInt32.max),
                UInt64(UInt32.max) + 1           // not even an index
            ]

            for index in cases {
                let request = frame(x0: UInt64(bus), x1: index)
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveDeviceSyscall.handle(frame: request, context: context)

                #expect(request.pointee.x0 == UInt64(UInt32.max))
            }
        }
    }


    /// The walk has no slot count to go on: it counts up until the bus says no.
    /// That refusal is therefore load bearing, and it has to come one past the
    /// last real transport rather than one page or one range later.
    @Test("the refusal that stops a walk comes right after the last transport")
    func theWalkStopsInTheRightPlace() {
        withBusHolder { _, bus, context in

            let last = frame(x0: UInt64(bus), x1: UInt64(Self.windows.count) - 1)
            defer { last.deinitialize(count: 1); last.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: last, context: context)
            #expect(last.pointee.x0 != UInt64(UInt32.max))
        }
    }


    // MARK: - The authority

    @Test("a bus without the right to derive hands out nothing")
    func deriveRightIsRequired() {
        withBusHolder(rights: [.read, .write]) { _, bus, context in
            let window = frame(x0: UInt64(bus), x1: 0)
            defer { window.deinitialize(count: 1); window.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: window, context: context)
            #expect(window.pointee.x0 == UInt64(UInt32.max))

            let line = frame(x0: UInt64(bus), x1: 0)
            defer { line.deinitialize(count: 1); line.deallocate() }

            BusDeriveInterruptSyscall.handle(frame: line, context: context)
            #expect(line.pointee.x0 == UInt64(UInt32.max))
        }
    }


    @Test("a read-only bus cannot mint a window that writes, or one that transfers")
    func rightsAreIntersected() {
        withBusHolder(rights: [.derive, .read]) { caller, bus, context in
            let request = frame(x0: UInt64(bus), x1: 0)
            defer { request.deinitialize(count: 1); request.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: request, context: context)

            let handle = UInt32(truncatingIfNeeded: request.pointee.x0)
            #expect(handle != UInt32.max)

            guard let rights = derived(caller, handle)?.rights else {
                Issue.record("the derived handle resolves to nothing")
                return
            }

            #expect(rights.contains(.read))
            #expect(!rights.contains(.write))

            // A bus that may not transfer cannot hand out a window that may.
            // `.dma` is the authority to turn an address into a physical one,
            // and it has to narrow with everything else.
            #expect(!rights.contains(.dma))
        }
    }


    @Test("a bus that may transfer passes that on to the windows it carves")
    func dmaIsPassedOn() {
        withBusHolder(rights: [.derive, .read, .write, .dma]) { caller, bus, context in
            let request = frame(x0: UInt64(bus), x1: 0)
            defer { request.deinitialize(count: 1); request.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: request, context: context)

            let handle = UInt32(truncatingIfNeeded: request.pointee.x0)
            #expect(handle != UInt32.max)
            #expect(derived(caller, handle)?.rights.contains(.dma) == true)
        }
    }


    @Test("a handle that names something other than a bus is refused")
    func onlyABusNarrows() {
        withBusHolder { caller, _, context in
            let device = caller.pointee.metadata?.pointee.capsTable.install(
                Capability(
                    target: .device(DeviceRegion(address: Self.windows[0].base, size: Self.slot)),
                    badge : Badge(0),
                    rights: [.derive, .read, .write]
                )
            )
            #expect(device != nil)

            for handle in [UInt64(device!), 15, UInt64(UInt32.max) + 1] {
                let request = frame(x0: handle, x1: 0)
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveDeviceSyscall.handle(frame: request, context: context)

                #expect(request.pointee.x0 == UInt64(UInt32.max))
            }
        }
    }


    // MARK: - The lines

    @Test("a slot the bus does not have raises no line")
    func indexIsBounded() {
        withBusHolder { _, bus, context in

            let cases: [UInt64] = [
                UInt64(Self.windows.count),
                UInt64(Self.windows.count) + 1,
                UInt64(UInt32.max) + 1
            ]

            for index in cases {
                let request = frame(x0: UInt64(bus), x1: index)
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveInterruptSyscall.handle(frame: request, context: context)

                #expect(request.pointee.x0 == UInt64(UInt32.max))
            }
        }
    }


    /// The claim is made against the line that transport really raises. Taking
    /// that line first has to be enough to make the derive fail, and it only is
    /// if the kernel looked the line up in the list rather than counting.
    @Test("a line already claimed is not handed out a second time")
    func oneLineHasOneOwner() {
        withBusHolder { _, bus, context in

            let taken = Self.windows[1].line

            let set = UnsafeMutablePointer<InterruptSet>.allocate(capacity: 1)
            set.initialize(to: InterruptSet())
            defer {
                InterruptClaims.releaseAll(of: set)
                set.deinitialize(count: 1)
                set.deallocate()
            }

            #expect(set.pointee.add(line: taken) != nil)
            #expect(InterruptClaims.claim(line: taken, by: set))

            let request = frame(x0: UInt64(bus), x1: 1)
            defer { request.deinitialize(count: 1); request.deallocate() }

            BusDeriveInterruptSyscall.handle(frame: request, context: context)

            #expect(request.pointee.x0 == UInt64(UInt32.max))
            #expect(InterruptClaims.owner(of: taken) == set)

            // And the line the old arithmetic would have reached for is not the
            // one that was taken, so this test could not pass by accident.
            #expect(Self.windows[0].line + 1 != taken)
        }
    }
}
