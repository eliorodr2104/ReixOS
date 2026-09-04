//
//  DmaAuthorityTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

/// Who may allocate a buffer a device can transfer into, and who may learn
/// where it physically is.
///
/// Both questions are the whole point of the design. There is no IOMMU on this
/// machine, so a physical address plus a device that transfers is authority over
/// all of memory, and the only thing standing between a process and that
/// authority is these two checks: a device capability **carrying `.dma`** to mint
/// the buffer, and a DMA capability to ask for the address. A shared region that
/// could answer the second question would be a second door to the same authority.
///
/// `.dma` is the newer half of the first check, and the one worth watching. Any
/// device window used to do, with any rights on it, so the console's window over
/// a UART opened the door as wide as the disk controller's did.
extension KernelPolicyTestRoot {
@Suite("DMA authority", .serialized)
struct DmaAuthorityTests {

    private func frame(x0: UInt64 = 0, x1: UInt64 = 0) -> UnsafeMutablePointer<Arch.TrapFrame> {
        let pointer = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        pointer.initialize(to: Arch.TrapFrame())
        pointer.pointee.x0 = x0
        pointer.pointee.x1 = x1

        return pointer
    }


    /// A live manager, a child process to act as the caller, and the syscall
    /// context the two DMA providers are handed.
    private func withCaller(
        _ body: (
            HostRAM,
            UnsafeMutablePointer<Process>,
            UnsafeMutablePointer<KernelIPC>,
            SyscallContext
        ) -> Void
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

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: caller)))
            defer { Arch.CPU.setCurrentProcess(0) }

            body(ram, caller, ipc, SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ))
        }
    }


    private func installDeviceCap(
        in process: UnsafeMutablePointer<Process>,
        rights    : CapRights = [.read, .write, .dma]
    ) -> UInt32? {
        process.pointee.metadata?.pointee.capsTable.install(
            Capability(
                target: .device(DeviceRegion(address: 0x0900_0000, size: 4096)),
                badge : Badge(0),
                rights: rights
            )
        )
    }


    @Test("a caller with no device capability is refused a DMA buffer")
    func deviceCapabilityIsRequired() {
        withCaller { ram, caller, _, context in
            let before  = ram.ppm.pointee.allocatedPages
            let request = frame(x0: 4, x1: 0)
            defer { request.deinitialize(count: 1); request.deallocate() }

            DmaAlloc.handle(frame: request, context: context)

            #expect(request.pointee.x0 == UInt64.max)
            #expect(request.pointee.x1 == 0)

            // Refused before anything was taken, not rolled back afterwards.
            #expect(ram.ppm.pointee.allocatedPages == before)
        }
    }


    @Test("a handle that names something other than a device is refused")
    func onlyADeviceCapabilityOpensIt() {
        withCaller { _, caller, ipc, context in
            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            let slot = caller.pointee.metadata?.pointee.capsTable.install(
                Capability(target: .endpoint(endpoint), badge: Badge(0), rights: [.send])
            )
            #expect(slot != nil)

            let request = frame(x0: 4, x1: UInt64(slot!))
            defer { request.deinitialize(count: 1); request.deallocate() }

            DmaAlloc.handle(frame: request, context: context)

            #expect(request.pointee.x0 == UInt64.max)
        }
    }


    @Test("a caller holding a device window gets a mapped, contiguous buffer")
    func deviceHolderGetsABuffer() {
        withCaller { ram, caller, _, context in
            guard let device = installDeviceCap(in: caller) else {
                Issue.record("could not install the device capability")
                return
            }

            reset_dcache_clean_record()

            let pages   = UInt64(4)
            let request = frame(x0: pages, x1: UInt64(device))
            defer { request.deinitialize(count: 1); request.deallocate() }

            DmaAlloc.handle(frame: request, context: context)

            #expect(request.pointee.x0 != UInt64.max)
            #expect(request.pointee.x1 != 0)

            // Contiguity is what a device needs and what one buddy block gives:
            // the whole buffer has to sit inside the arena from one base.
            let query = frame(x0: request.pointee.x0)
            defer { query.deinitialize(count: 1); query.deallocate() }

            DmaPhysical.handle(frame: query, context: context)

            let physical = query.pointee.x0
            #expect(physical != UInt64.max)
            #expect(physical % 4096 == 0)
            #expect(physical >= ram.base)
            #expect(physical <= ram.end - pages * 4096)

            // Handed over zeroed, and pushed out of the cache the kernel zeroed
            // it through. The mapping userland gets is non-cacheable, so a line
            // left behind is either stale bytes the device reads instead of
            // zeros, or a write-back that lands on top of what it wrote.
            #expect(dcache_clean_calls() == 1)
            #expect(dcache_cleaned_size() == pages * 4096)
        }
    }


    /// The hole this closes. A device window is permission to drive one device;
    /// a physical address, with nothing between a device and memory, is the whole
    /// of RAM. Holding the first used to be enough to be handed the second.
    @Test("a device window that does not say DMA mints no buffer")
    func dmaRightIsRequired() {
        withCaller { ram, caller, _, context in

            let before = ram.ppm.pointee.allocatedPages

            // Every shape of device window that is not allowed to transfer,
            // including the one the console actually holds.
            let refused: [CapRights] = [
                [.read],
                [.read, .write],
                [.grant, .read, .write],
                [.derive, .read, .write, .grant]
            ]

            for rights in refused {
                guard let device = installDeviceCap(in: caller, rights: rights) else {
                    Issue.record("could not install the device capability")
                    return
                }

                let request = frame(x0: 4, x1: UInt64(device))
                defer { request.deinitialize(count: 1); request.deallocate() }

                DmaAlloc.handle(frame: request, context: context)

                #expect(request.pointee.x0 == UInt64.max)
                #expect(request.pointee.x1 == 0)
            }

            // Refused before anything was taken, every time.
            #expect(ram.ppm.pointee.allocatedPages == before)
        }
    }


    /// The buffer is cleaned over itself: the bytes the kernel zeroed and no
    /// others. Cleaning less leaves part of it stale; the address has to be the
    /// kernel's own mapping, because that is the alias the zeros went through.
    @Test("the cache is cleaned over exactly the buffer that was zeroed")
    func cleanCoversTheBuffer() {
        withCaller { _, caller, _, context in
            guard let device = installDeviceCap(in: caller) else {
                Issue.record("could not install the device capability")
                return
            }

            for pages in [UInt64(1), 4, 64] {
                reset_dcache_clean_record()

                let request = frame(x0: pages, x1: UInt64(device))
                defer { request.deinitialize(count: 1); request.deallocate() }

                DmaAlloc.handle(frame: request, context: context)
                #expect(request.pointee.x0 != UInt64.max)

                #expect(dcache_clean_calls()  == 1)
                #expect(dcache_cleaned_size() == pages * 4096)
                #expect(dcache_cleaned_base() != 0)
            }
        }
    }


    @Test("an ordinary shared region refuses to give up its physical address")
    func sharedRegionsStaySilent() {
        withCaller { ram, caller, ipc, context in
            guard let page = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena could not spare a page")
                return
            }

            guard case .success(let created) = ipc.pointee.createShared(
                for      : caller,
                page     : page,
                pageCount: 1
            ) else {
                Issue.record("could not create the shared region")
                return
            }

            let query = frame(x0: UInt64(created.handle))
            defer { query.deinitialize(count: 1); query.deallocate() }

            DmaPhysical.handle(frame: query, context: context)

            // The two capabilities name the same kind of object. The refusal
            // here is the entire difference between them, and it is why the DMA
            // buffer needed a capability kind of its own rather than a flag.
            #expect(query.pointee.x0 == UInt64.max)
        }
    }


    @Test("a handle that names nothing, or names an endpoint, gets no address")
    func addressRefusedForNonBuffers() {
        withCaller { _, caller, _, context in
            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            let slot = caller.pointee.metadata?.pointee.capsTable.install(
                Capability(target: .endpoint(endpoint), badge: Badge(0), rights: [.send])
            )
            #expect(slot != nil)

            for handle in [UInt64(slot!), 15, UInt64(UInt32.max) + 1] {
                let query = frame(x0: handle)
                defer { query.deinitialize(count: 1); query.deallocate() }

                DmaPhysical.handle(frame: query, context: context)
                #expect(query.pointee.x0 == UInt64.max)
            }
        }
    }


    @Test("a zero-page or oversized request is refused")
    func sizeBounds() {
        withCaller { ram, caller, _, context in
            guard let device = installDeviceCap(in: caller) else {
                Issue.record("could not install the device capability")
                return
            }

            let before = ram.ppm.pointee.allocatedPages
            reset_dcache_clean_record()

            for pages in [UInt64(0), 257, UInt64.max] {
                let request = frame(x0: pages, x1: UInt64(device))
                defer { request.deinitialize(count: 1); request.deallocate() }

                DmaAlloc.handle(frame: request, context: context)
                #expect(request.pointee.x0 == UInt64.max)
            }

            #expect(ram.ppm.pointee.allocatedPages == before)

            // Nothing zeroed, so nothing to clean.
            #expect(dcache_clean_calls() == 0)
        }
    }
}


}
