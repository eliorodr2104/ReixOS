//
//  SyscallHandleWidthTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// A handle is thirty-two bits and a register is sixty-four.
///
/// Every test here does the same thing: install a capability at some handle,
/// then ask for `(1 << 32) | handle`. The low half is a real slot, so a provider
/// that narrows the register instead of refusing it resolves that slot and
/// serves the request. The pair of expectations is what makes each one
/// discriminating: the plain handle is served, and the wide one is not.
///
/// `.serialized`, and the run needs `--no-parallel`, for `ForkSpawnTests`'
/// reason: `PPMBackend.physicalOffset` and `ProcessStatsIndex` are global.
extension KernelPolicyTestRoot {
@Suite("Syscall handle width", .serialized)
struct SyscallHandleWidthTests {

    /// The same handle with a bit nothing can hold set above it.
    private static func widened(_ handle: UInt32) -> UInt64 {
        (UInt64(1) << 32) | UInt64(handle)
    }


    private func withCaller(
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


    /// Runs one provider over a fresh frame and answers what it wrote to `x0`.
    private func answer(
        _ provider: any SyscallProvider.Type,
        x0        : UInt64,
        x1        : UInt64 = 0,
        _ context : SyscallContext
    ) -> UInt64 {
        let frame = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        frame.initialize(to: Arch.TrapFrame())
        defer { frame.deinitialize(count: 1); frame.deallocate() }

        frame.pointee.x0 = x0
        frame.pointee.x1 = x1

        provider.handle(frame: frame, context: context)

        return frame.pointee.x0
    }


    /// `shmCreate(pages)`, answering the handle it minted.
    private func region(
        pages     : UInt64,
        _ context : SyscallContext,
        device    : UInt64? = nil
    ) -> UInt32? {
        let frame = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        frame.initialize(to: Arch.TrapFrame())
        defer { frame.deinitialize(count: 1); frame.deallocate() }

        frame.pointee.x0 = pages

        if let device {
            frame.pointee.x1 = device
            DmaAlloc.handle(frame: frame, context: context)

        } else {
            ShmCreate.handle(frame: frame, context: context)
        }

        guard frame.pointee.x0 != UInt64.max else { return nil }

        return UInt32(truncatingIfNeeded: frame.pointee.x0)
    }


    // MARK: - The helper itself

    @Test("the shared check refuses exactly what a handle cannot hold")
    func helperBoundary() {
        #expect(SyscallABI.handle(0)                     == 0)
        #expect(SyscallABI.handle(UInt64(UInt32.max))    == UInt32.max)
        #expect(SyscallABI.handle(UInt64(UInt32.max) + 1) == nil)
        #expect(SyscallABI.handle(UInt64.max)            == nil)
        #expect(SyscallABI.handle(Self.widened(3))       == nil)

        #expect(SyscallABI.count(256, atMost: 256) == 256)
        #expect(SyscallABI.count(257, atMost: 256) == nil)
        #expect(SyscallABI.count(Self.widened(4), atMost: 256) == nil)

        // The profiling family's two names are the same check, not a copy.
        #expect(ProfileABI.authorityHandle(Self.widened(1)) == nil)
        #expect(ProfileABI.attachHandle(Self.widened(1))    == nil)
    }


    // MARK: - RXMemory

    @Test("shmMap, shmPages, dmaPhysical and dmaReclaim refuse a handle that does not fit")
    func memoryProviders() {
        withCaller { _, _, _, _, caller, context in
            guard let shared = region(pages: 2, context) else {
                Issue.record("could not mint the shared region")
                return
            }

            #expect(answer(ShmPages.self, x0: UInt64(shared), context) == 2)
            #expect(answer(ShmPages.self, x0: Self.widened(shared), context) == 0)

            #expect(answer(ShmMap.self, x0: UInt64(shared), x1: 1, context) != 0)
            #expect(answer(ShmMap.self, x0: Self.widened(shared), x1: 1, context) == 0)

            // A DMA buffer needs a device window carrying `.dma` to exist at
            // all, so this exercises `dmaAlloc`'s device handle as well.
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

            #expect(region(pages: 1, context, device: Self.widened(device)) == nil)

            guard let dma = region(pages: 1, context, device: UInt64(device)) else {
                Issue.record("could not mint the DMA buffer")
                return
            }

            #expect(answer(DmaPhysical.self, x0: UInt64(dma), context) != UInt64.max)
            #expect(answer(DmaPhysical.self, x0: Self.widened(dma), context) == UInt64.max)

            #expect(answer(DmaReclaim.self, x0: UInt64(device), context) == 0)
            #expect(answer(DmaReclaim.self, x0: Self.widened(device), context) == UInt64.max)
        }
    }


    // MARK: - RXIPC

    @Test("the capability providers refuse a handle that does not fit")
    func ipcProviders() {
        withCaller { _, _, _, ipc, caller, context in
            guard case .success(let endpoint) = ipc.pointee.spawnEndpoint(for: caller) else {
                Issue.record("could not mint the endpoint")
                return
            }

            #expect(answer(CapExistsSyscall.self, x0: UInt64(endpoint), context) == 1)
            #expect(answer(CapExistsSyscall.self, x0: Self.widened(endpoint), context) == 0)

            // A send that resolved the narrowed handle would find a real
            // endpoint and park on it; refused, it says so and parks nothing.
            #expect(
                answer(TrySendSyscall.self, x0: Self.widened(endpoint), context)
                    == IPCStatus.invalidCapability.rawValue
            )
            #expect(caller.pointee.pending == nil)

            #expect(answer(DeriveSyscall.self, x0: Self.widened(endpoint), x1: 7, context)
                    == UInt64(UInt32.max))

            #expect(answer(MapDeviceSyscall.self, x0: Self.widened(endpoint), context) == 0)

            // Refused, and the capability is still where it was: a narrowed
            // handle would have dropped it.
            #expect(answer(CapDropSyscall.self, x0: Self.widened(endpoint), context) == UInt64.max)
            #expect(caller.pointee.metadata.pointee.capsTable.resolve(endpoint) != nil)

            #expect(answer(CapDropSyscall.self, x0: UInt64(endpoint), context) == 0)
            #expect(caller.pointee.metadata.pointee.capsTable.resolve(endpoint) == nil)
        }
    }


    @Test("the bus and device window resolvers refuse a handle that does not fit")
    func busAndDeviceResolvers() {
        withCaller { _, _, _, _, caller, _ in
            guard let window = caller.pointee.metadata.pointee.capsTable.install(
                Capability(
                    target: .device(DeviceRegion(address: 0x0900_0000, size: 4096)),
                    badge : Badge(0),
                    rights: [.read, .write]
                )
            ) else {
                Issue.record("could not install the device window")
                return
            }

            #expect(DeviceAccess.address(
                handle : UInt64(window),
                offset : 0,
                needing: .read,
                of     : caller
            ) != nil)

            #expect(DeviceAccess.address(
                handle : Self.widened(window),
                offset : 0,
                needing: .read,
                of     : caller
            ) == nil)

            #expect(BusAccess.authority(handle: Self.widened(window), of: caller) == nil)
        }
    }


    // MARK: - RXIO and RXTask

    @Test("the interrupt and task resolvers refuse a handle that does not fit")
    func interruptAndTaskResolvers() {
        withCaller { _, heap, manager, _, caller, _ in
            guard let set = heap.pointee.kmallocOrNil(InterruptSet.self) else {
                Issue.record("could not allocate the interrupt set")
                return
            }
            set.initialize(to: InterruptSet())
            defer { heap.pointee.kfree(set) }

            guard let line = caller.pointee.metadata.pointee.capsTable.install(
                Capability(target: .interrupt(set), badge: Badge(0), rights: [.grant])
            ) else {
                Issue.record("could not install the interrupt capability")
                return
            }

            #expect(InterruptAuthority.resolve(handle: UInt64(line), of: caller) == set)
            #expect(InterruptAuthority.resolve(handle: Self.widened(line), of: caller) == nil)

            guard let created = manager.pointee.createSuspendedTask(ownedBy: caller) else {
                Issue.record("could not create the suspended task")
                return
            }

            guard let task = caller.pointee.metadata.pointee.capsTable.install(
                Capability(
                    target: .task(created.control),
                    badge : Badge(0),
                    rights: [.taskStatus, .taskConfigure]
                )
            ) else {
                Issue.record("could not install the task capability")
                return
            }

            #expect(TaskCapabilityAccess.status(rawHandle: UInt64(task), current: caller) != nil)
            #expect(TaskCapabilityAccess.status(rawHandle: Self.widened(task), current: caller) == nil)

            #expect(TaskCapabilityAccess.task(
                rawHandle: Self.widened(task),
                right    : .taskConfigure,
                current  : caller
            ) == nil)
        }
    }
}
}
