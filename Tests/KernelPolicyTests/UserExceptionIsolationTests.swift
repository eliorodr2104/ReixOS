import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

extension KernelPolicyTestRoot {
@Suite("User exception isolation", .serialized)
struct UserExceptionIsolationTests {
    @Test("BRK and PC alignment faults terminate the user task and resume a peer")
    func userTraps() {
        for exceptionClass: UInt64 in [0x3C, 0x22] {
            withProcessManager(pages: 128) { ram, heap, manager in
                let scheduler = UnsafeMutablePointer<KernelScheduler>.allocate(capacity: 1)
                scheduler.initialize(to: RoundRobin())
                defer { scheduler.deinitialize(count: 1); scheduler.deallocate() }
                let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
                ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
                defer { ipc.deinitialize(count: 1); ipc.deallocate() }
                let handler = UnsafeMutablePointer<SyscallHandler>.allocate(capacity: 1)
                handler.initialize(to: SyscallHandler(processManager: manager, scheduler: scheduler,
                                                      ipc: ipc, ppm: ram.ppm))
                defer { handler.deinitialize(count: 1); handler.deallocate() }
                let savedScheduler: UnsafeMutablePointer<KernelScheduler>? = Kernel.scheduler
                let savedHandler: UnsafeMutablePointer<SyscallHandler>? = Kernel.syscallHandler
                Kernel.scheduler = scheduler
                Kernel.syscallHandler = handler
                defer { Kernel.scheduler = savedScheduler; Kernel.syscallHandler = savedHandler }
                guard let peer = try? manager.pointee.spawnProcess(),
                      let victim = try? manager.pointee.spawnProcess()
                else { Issue.record("could not create exception fixture"); return }
                manager.pointee.initProcess = peer
                defer { manager.pointee.initProcess = nil }
                peer.pointee.family.pushChild(victim)
                victim.pointee.family.parent = peer
                do { try scheduler.pointee.addTask(peer) }
                catch { Issue.record("could not schedule peer"); return }
                victim.pointee.status = .running
                Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: victim)))
                defer { Arch.CPU.setCurrentProcess(0) }
                var frame = Arch.TrapFrame()
                frame.spsr = 0
                frame.esr = exceptionClass << 26
                withUnsafeMutablePointer(to: &frame) { pointer in
                    exceptionVirtualTableHandler(rawFramePointer: UnsafeMutableRawPointer(pointer),
                                                 type: ExceptionType.synchronous.rawValue)
                }
                if case .illegalInstruction? = victim.pointee.metadata.pointee.exitReason {} else {
                    Issue.record("user fault did not terminate with illegalInstruction")
                }
                #expect(Arch.CPU.getCurrentProcess() == peer)
                #expect(frame.elr == peer.pointee.context?.pointee.elr)
            }
        }
    }
}
}
