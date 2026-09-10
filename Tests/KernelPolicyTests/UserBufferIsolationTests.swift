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
}
}
