import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

extension KernelPolicyTestRoot {
@Suite("User buffer isolation", .serialized)
struct UserBufferIsolationTests {
    @Test("writable SHM attachment refuses a read-only grant before allocating")
    func writableAttachment() {
        withProcessManager(pages: 96) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }
            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }
            guard let caller = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create caller"); return
            }
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: caller)))
            defer { Arch.CPU.setCurrentProcess(0) }
            let context = SyscallContext(processManager: manager, scheduler: scheduler,
                                         ipc: ipc, ppm: ram.ppm)
            var create = Arch.TrapFrame()
            create.x0 = 1
            ShmCreate.handle(frame: &create, context: context)
            guard let capability = caller.pointee.metadata.pointee.capsTable.resolve(UInt32(truncatingIfNeeded: create.x0)),
                  let readOnly = caller.pointee.metadata.pointee.capsTable.install(
                    Capability(target: capability.target, badge: 0, rights: [.read])
                  )
            else { Issue.record("could not create shared region"); return }
            if case .shared(let region) = capability.target { retainSharedRegion(region) }

            let before = ram.ppm.pointee.allocatedPages
            var denied = Arch.TrapFrame()
            denied.x0 = UInt64(readOnly)
            denied.x1 = 1
            ShmMap.handle(frame: &denied, context: context)
            #expect(denied.x0 == 0)
            #expect(ram.ppm.pointee.allocatedPages == before)

            var read = Arch.TrapFrame()
            read.x0 = UInt64(readOnly)
            ShmMap.handle(frame: &read, context: context)
            #expect(read.x0 != 0)
            #expect(caller.pointee.addressSpace.vmaManager?.pointee.isPageMapped(at: read.x0, writable: true) == false)

            var write = Arch.TrapFrame()
            write.x0 = create.x0
            write.x1 = 1
            ShmMap.handle(frame: &write, context: context)
            #expect(write.x0 != 0)
            #expect(caller.pointee.addressSpace.vmaManager?.pointee.isPageMapped(at: write.x0, writable: true) == true)
        }
    }

    @Test("kernel output validation resolves COW without altering the sibling")
    func copyOnWriteOutput() {
        withProcessManager(pages: 128) { ram, _, manager in
            guard let parent = try? manager.pointee.spawnProcess(),
                  let child = try? manager.pointee.spawnProcess(),
                  let parentVMA = parent.pointee.addressSpace.vmaManager,
                  let childVMA = child.pointee.addressSpace.vmaManager,
                  let address = try? parentVMA.pointee.mmapAnonymous(
                    size: 4096, permissions: [.read, .write, .user]
                  )
            else { Issue.record("could not create COW fixture"); return }
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: parent)))
            defer { Arch.CPU.setCurrentProcess(0) }
            #expect(UserMemory.validateRegion(addr: address, size: 4096, permissions: [.read, .write, .user]))
            guard let original = ram.vmm.pointee.physicalAddressOf(
                rootTable: parent.pointee.addressSpace.rootTablePhysical, virtual: address
            ) else { Issue.record("missing parent page"); return }
            let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(original)
            bytes[0] = 0x5A
            do { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            catch { Issue.record("clone failed: \(error)"); return }
            #expect(!childVMA.pointee.isPageMapped(at: address, writable: true))
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: child)))
            #expect(UserMemory.validateRegion(addr: address, size: 1, permissions: [.read, .write, .user]))
            #expect(childVMA.pointee.isPageMapped(at: address, writable: true))
            guard let copied = ram.vmm.pointee.physicalAddressOf(
                rootTable: child.pointee.addressSpace.rootTablePhysical, virtual: address
            ) else { Issue.record("missing child page"); return }
            #expect(copied != original)
            let childBytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(copied)
            #expect(childBytes[0] == 0x5A)
            childBytes[0] = 0xA5
            #expect(bytes[0] == 0x5A)
        }
    }
}
}
