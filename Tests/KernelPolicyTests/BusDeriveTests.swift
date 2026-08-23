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
/// hardware, so every bound it applies is the only bound there is. Carve one
/// byte past the end and the window reaches the next machine's registers; round
/// the size up and it reaches its neighbours; forget to intersect the rights and
/// a bus held read-only mints something that writes.
///
/// The interrupt side is tested for its refusals only. Succeeding at it ends in
/// a write to the distributor, and there is no distributor on this host.
@Suite("Bus narrowing", .serialized)
struct BusDeriveTests {

    private static let busBase : UInt64 = 0x0A00_0000
    private static let busSize : UInt64 = 0x4000       // 32 slots of 0x200
    private static let firstLine: UInt32 = 48
    private static let lineCount: UInt32 = 32
    private static let slot    : UInt64 = 0x200


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
            bus.initialize(to: BusAuthority(
                base     : Self.busBase,
                size     : Self.busSize,
                firstLine: Self.firstLine,
                lineCount: Self.lineCount
            ))
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


    // MARK: - The arithmetic on its own

    @Test("the slot index names the line the machine said it would")
    func lineFollowsTheSlot() {
        let bus = BusAuthority(
            base     : Self.busBase,
            size     : Self.busSize,
            firstLine: Self.firstLine,
            lineCount: Self.lineCount
        )

        #expect(bus.line(at: 0)  == Self.firstLine)
        #expect(bus.line(at: 31) == Self.firstLine + 31)
        #expect(bus.line(at: Self.lineCount) == nil)
        #expect(bus.line(at: UInt32.max) == nil)

        let silent = BusAuthority(base: Self.busBase, size: Self.busSize, firstLine: 48, lineCount: 0)
        #expect(silent.line(at: 0) == nil)
    }


    // MARK: - The extent

    @Test("a slot is carved where it was asked for, at the size it was asked for")
    func windowIsExact() {
        withBusHolder { caller, bus, context in
            let request = frame(x0: UInt64(bus), x1: 31 * Self.slot, x2: Self.slot)
            defer { request.deinitialize(count: 1); request.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: request, context: context)

            let handle = UInt32(truncatingIfNeeded: request.pointee.x0)
            #expect(handle != UInt32.max)

            guard case .device(let window)? = derived(caller, handle)?.target else {
                Issue.record("the derived handle does not name a device window")
                return
            }

            #expect(window.address == Self.busBase + 31 * Self.slot)

            // Not rounded up to a page. Rounding is what would hand over the
            // seven neighbouring slots along with this one.
            #expect(window.size == Self.slot)
        }
    }


    @Test("a window that runs past the end of the bus is refused")
    func pastTheEndIsRefused() {
        withBusHolder { caller, bus, context in
            let cases: [(UInt64, UInt64)] = [
                (Self.busSize, Self.slot),              // starts at the end
                (Self.busSize - 0x100, Self.slot),      // straddles the end
                (Self.busSize + 0x1000, Self.slot),     // past it entirely
                (0, Self.busSize + 1),                  // wider than the bus
                (0, 0),                                 // empty
                (UInt64.max, Self.slot)                 // would wrap
            ]

            for (offset, size) in cases {
                let request = frame(x0: UInt64(bus), x1: offset, x2: size)
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveDeviceSyscall.handle(frame: request, context: context)

                #expect(request.pointee.x0 == UInt64(UInt32.max))
            }
        }
    }


    @Test("the last byte of the bus is still inside it")
    func theEndIsInclusive() {
        withBusHolder { _, bus, context in
            let request = frame(x0: UInt64(bus), x1: Self.busSize - Self.slot, x2: Self.slot)
            defer { request.deinitialize(count: 1); request.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: request, context: context)

            #expect(request.pointee.x0 != UInt64(UInt32.max))
        }
    }


    // MARK: - The authority

    @Test("a bus without the right to derive hands out nothing")
    func deriveRightIsRequired() {
        withBusHolder(rights: [.read, .write]) { _, bus, context in
            let window = frame(x0: UInt64(bus), x1: 0, x2: Self.slot)
            defer { window.deinitialize(count: 1); window.deallocate() }

            BusDeriveDeviceSyscall.handle(frame: window, context: context)
            #expect(window.pointee.x0 == UInt64(UInt32.max))

            let line = frame(x0: UInt64(bus), x1: 0)
            defer { line.deinitialize(count: 1); line.deallocate() }

            BusDeriveInterruptSyscall.handle(frame: line, context: context)
            #expect(line.pointee.x0 == UInt64(UInt32.max))
        }
    }


    @Test("a read-only bus cannot mint a window that writes")
    func rightsAreIntersected() {
        withBusHolder(rights: [.derive, .read]) { caller, bus, context in
            let request = frame(x0: UInt64(bus), x1: 0, x2: Self.slot)
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
        }
    }


    @Test("a handle that names something other than a bus is refused")
    func onlyABusNarrows() {
        withBusHolder { caller, _, context in
            let device = caller.pointee.metadata?.pointee.capsTable.install(
                Capability(
                    target: .device(DeviceRegion(address: Self.busBase, size: Self.slot)),
                    badge : Badge(0),
                    rights: [.derive, .read, .write]
                )
            )
            #expect(device != nil)

            for handle in [UInt64(device!), 15, UInt64(UInt32.max) + 1] {
                let request = frame(x0: handle, x1: 0, x2: Self.slot)
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
            for index in [UInt64(Self.lineCount), UInt64(Self.lineCount) + 1, UInt64(UInt32.max) + 1] {
                let request = frame(x0: UInt64(bus), x1: index)
                defer { request.deinitialize(count: 1); request.deallocate() }

                BusDeriveInterruptSyscall.handle(frame: request, context: context)

                #expect(request.pointee.x0 == UInt64(UInt32.max))
            }
        }
    }


    @Test("a line already claimed is not handed out a second time")
    func oneLineHasOneOwner() {
        withBusHolder { _, bus, context in
            let set = UnsafeMutablePointer<InterruptSet>.allocate(capacity: 1)
            set.initialize(to: InterruptSet())
            defer {
                InterruptClaims.releaseAll(of: set)
                set.deinitialize(count: 1)
                set.deallocate()
            }

            // The line the seventh slot raises, taken by somebody else first.
            #expect(set.pointee.add(line: Self.firstLine + 7) != nil)
            #expect(InterruptClaims.claim(line: Self.firstLine + 7, by: set))

            let request = frame(x0: UInt64(bus), x1: 7)
            defer { request.deinitialize(count: 1); request.deallocate() }

            BusDeriveInterruptSyscall.handle(frame: request, context: context)

            #expect(request.pointee.x0 == UInt64(UInt32.max))
            #expect(InterruptClaims.owner(of: Self.firstLine + 7) == set)
        }
    }


}
