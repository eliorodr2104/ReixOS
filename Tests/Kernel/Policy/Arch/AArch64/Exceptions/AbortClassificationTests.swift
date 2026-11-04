//
//  AbortClassificationTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// What `userAbortHandle` reads out of ESR_EL1, driven the way
/// `UserExceptionIsolationTests` drives a trap: a synthetic frame through
/// `exceptionVirtualTableHandler`, with the exit reason read back off the
/// corpse.
///
/// The exit reason is the only place the decoding is observable from outside
/// the handler, and that is the point: it is what a `[SEGFAULT]` line and a
/// process's recorded death say happened. An exception class of 0x20 has to
/// read as a fetch whatever bit 6 of the ISS holds, because `WnR` belongs to a
/// data abort and an instruction abort reuses the bit.
///
/// `.serialized`, and the run needs `--no-parallel`: `Kernel.scheduler`,
/// `Kernel.syscallHandler` and the current process are global.
extension KernelPolicyTestRoot {
@Suite("User abort classification", .serialized)
struct AbortClassificationTests {

    /// Permission fault, level 3. Any DFSC in `0x0C...0x0F` classifies the
    /// same; this is the one a leaf descriptor raises.
    private static let permissionDFSC: UInt64 = 0x0F

    /// Translation fault, level 3, the DFSC of an absent leaf descriptor.
    private static let translationDFSC: UInt64 = 0x07

    private static let writeNotRead: UInt64 = 1 << 6


    /// Runs one synthetic user abort against a process that maps nothing, and
    /// answers the reason it died of.
    ///
    /// Nothing is mapped on purpose: the address is outside every region, so
    /// the VMA layer refuses whatever it is handed and the reason carries the
    /// decoding untouched.
    private func reason(
        exceptionClass: UInt64,
        iss           : UInt64,
        far           : UInt64 = 0x4000
    ) -> ExitReason? {

        var recorded: ExitReason? = nil

        withProcessManager(pages: 128) { ram, heap, manager in
            let scheduler = UnsafeMutablePointer<KernelScheduler>.allocate(capacity: 1)
            scheduler.initialize(to: RoundRobin())
            defer { scheduler.deinitialize(count: 1); scheduler.deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let handler = UnsafeMutablePointer<SyscallHandler>.allocate(capacity: 1)
            handler.initialize(to: SyscallHandler(
                processManager: manager, scheduler: scheduler, ipc: ipc, ppm: ram.ppm
            ))
            defer { handler.deinitialize(count: 1); handler.deallocate() }

            let savedScheduler: UnsafeMutablePointer<KernelScheduler>? = Kernel.scheduler
            let savedHandler  : UnsafeMutablePointer<SyscallHandler>?  = Kernel.syscallHandler
            Kernel.scheduler      = scheduler
            Kernel.syscallHandler = handler
            defer { Kernel.scheduler = savedScheduler; Kernel.syscallHandler = savedHandler }

            guard let peer   = try? manager.pointee.spawnProcess(),
                  let victim = try? manager.pointee.spawnProcess()
            else {
                Issue.record("could not create the abort fixture")
                return
            }

            manager.pointee.initProcess = peer
            defer { manager.pointee.initProcess = nil }

            peer.pointee.family.pushChild(victim)
            victim.pointee.family.parent = peer

            do { try scheduler.pointee.addTask(peer) }
            catch {
                Issue.record("could not schedule the peer")
                return
            }

            victim.pointee.status = .running
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: victim)))
            defer { Arch.CPU.setCurrentProcess(0) }

            var frame = Arch.TrapFrame()
            frame.spsr = 0
            frame.esr  = (exceptionClass << 26) | iss
            frame.far  = far

            withUnsafeMutablePointer(to: &frame) { pointer in
                exceptionVirtualTableHandler(
                    rawFramePointer: UnsafeMutableRawPointer(pointer),
                    type           : ExceptionType.synchronous.rawValue
                )
            }

            recorded = victim.pointee.metadata.pointee.exitReason
        }

        return recorded
    }


    @Test("an instruction abort is a fetch whatever the ISS write bit says")
    func instructionAbortIsAFetch() {
        for iss in [Self.permissionDFSC, Self.permissionDFSC | Self.writeNotRead] {
            guard case .memoryFault(let cause, let access)? = reason(
                exceptionClass: 0x20,
                iss           : iss
            ) else {
                Issue.record("an instruction abort did not record a memory fault")
                continue
            }

            #expect(cause  == .permission)
            #expect(access == .instructionFetch)
        }
    }


    @Test("a data abort reads its direction off the ISS write bit")
    func dataAbortReadsWnR() {
        guard case .memoryFault(_, let read)? = reason(
            exceptionClass: 0x24,
            iss           : Self.permissionDFSC
        ) else {
            Issue.record("a data read abort did not record a memory fault")
            return
        }
        #expect(read == .read)

        guard case .memoryFault(let cause, let write)? = reason(
            exceptionClass: 0x24,
            iss           : Self.permissionDFSC | Self.writeNotRead
        ) else {
            Issue.record("a data write abort did not record a memory fault")
            return
        }
        #expect(cause == .permission)
        #expect(write == .write)
    }


    @Test("the DFSC still decides the cause")
    func dfscDecidesTheCause() {
        guard case .memoryFault(let cause, let access)? = reason(
            exceptionClass: 0x24,
            iss           : Self.translationDFSC | Self.writeNotRead
        ) else {
            Issue.record("a translation abort did not record a memory fault")
            return
        }

        #expect(cause  == .translation)
        #expect(access == .write)
    }
}
}
