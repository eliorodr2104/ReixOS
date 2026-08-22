//
//  ProcStatsSyscallTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Three globals here: `ProcessStatsIndex`, `UserMemory.validationOverride` and the
/// host shim's current process, which `withCurrentProcess` installs and clears.
/// `.serialized` orders this suite's tests without excluding other suites, so the
/// run needs `swift test --no-parallel` (see the `test` target in the Makefile):
/// nothing else stops another suite from writing the same three.
///
/// Every refusal below is now attributable to the thing it names. The caller holds
/// the authority throughout, so a rejected buffer is rejected for being a bad
/// buffer; until the shim became stateful no caller could be resolved at all and
/// these tests all stopped at the authority check, one line into the syscall.
@Suite("ProcStats syscall", .serialized)
struct ProcStatsSyscallTests {

    /// Where the caller's profiler capability is installed, and what `x3` names.
    /// `BootCap.profiler` is the slot the kernel seeds at spawn time, so the frames
    /// below carry the handle a real caller would have been handed.
    private let authorityHandle = BootCap.profiler.rawValue

    @Test("process operation copies exactly one 48-byte record")
    func exactCopyout() {
        withAuthorizedProcess(pid: 41) { process in
            process.pointee.cpuTime = 1234
            process.pointee.status  = .ready

            withBuffer(fill: 0xA5) { buffer in
                UserMemory.validationOverride = { address, size, permissions in
                    address == UInt64(UInt(bitPattern: buffer)) &&
                    size == 48 && permissions == [.write, .user]
                }

                var frame = processFrame(buffer: buffer)
                ProcStatsSyscall.handle(frame: &frame, context: unusedContext())

                #expect(frame.x0 == 41)
                let stats = buffer.load(as: ProcessStats.self)
                #expect(stats.pid == 41)
                #expect(stats.cpuTime == 1234)
                #expect(stats.status == ProcessStatusCode.ready.rawValue)

                // A record is 48 bytes and the copy is one struct store, so the rest of
                // the buffer has to still carry the fill.
                #expect(Array(UnsafeBufferPointer(start: buffer.advanced(by: 48).assumingMemoryBound(to: UInt8.self), count: 16)) == Array(repeating: 0xA5, count: 16))
            }
        }
    }

    @Test("the same call without the capability copies nothing")
    func refusedWithoutAuthority() {
        withProcesses([41], resettingStatsIndex: true) { processes in
            let process = processes[0]
            process.pointee.status = .ready
            #expect(ProcessManager.registerForProcStats(process))

            // `exactCopyout`'s caller with its capability taken away: a metadata block
            // whose caps table is empty, so `x3` resolves to nothing.
            attachMetadata(to: process)
            defer { destroyMetadata(of: process) }
            #expect(process.pointee.metadata.pointee.capsTable.resolve(authorityHandle) == nil)

            withBuffer(fill: 0x5A) { buffer in
                UserMemory.validationOverride = { _, _, _ in true }

                withCurrentProcess(process) {
                    var frame = processFrame(buffer: buffer)
                    ProcStatsSyscall.handle(frame: &frame, context: unusedContext())

                    #expect(frame.x0 == UInt64.max)
                    #expect(bytes(buffer) == Array(repeating: 0x5A, count: 64))
                }
            }
        }
    }

    @Test("misaligned buffer is rejected without writing")
    func misalignedBuffer() {
        withAuthorizedProcess(pid: 1) { _ in
            withBuffer(fill: 0x6D) { buffer in
                // Validation is made to succeed, so the alignment guard is the only
                // thing left that can refuse: delete it and this test fails.
                UserMemory.validationOverride = { _, _, _ in true }

                var frame = processFrame(buffer: buffer + 1)
                ProcStatsSyscall.handle(frame: &frame, context: unusedContext())
                #expect(frame.x0 == UInt64.max)
                #expect(bytes(buffer) == Array(repeating: 0x6D, count: 64))
            }
        }
    }

    @Test("partial and unmapped buffers are rejected")
    func invalidMappings() {
        withAuthorizedProcess(pid: 1) { _ in
            withBuffer(fill: 0x7E) { buffer in
                let base = UInt64(UInt(bitPattern: buffer))

                UserMemory.validationOverride = { address, size, _ in
                    address == base && size <= 47
                }
                var partial = processFrame(buffer: buffer)
                ProcStatsSyscall.handle(frame: &partial, context: unusedContext())
                #expect(partial.x0 == UInt64.max)
                #expect(bytes(buffer) == Array(repeating: 0x7E, count: 64))

                UserMemory.validationOverride = { _, _, _ in false }
                var unmapped = processFrame(buffer: buffer)
                ProcStatsSyscall.handle(frame: &unmapped, context: unusedContext())
                #expect(unmapped.x0 == UInt64.max)
                #expect(bytes(buffer) == Array(repeating: 0x7E, count: 64))
            }
        }
    }

    @Test("terminator returns max and leaves the buffer unchanged")
    func terminalCursor() {
        withAuthorizedProcess(pid: 9) { _ in
            withBuffer(fill: 0xC3) { buffer in
                UserMemory.validationOverride = { _, size, _ in size == 48 }
                var frame = processFrame(cursor: 9, buffer: buffer)
                ProcStatsSyscall.handle(frame: &frame, context: unusedContext())
                #expect(frame.x0 == UInt64.max)
                #expect(bytes(buffer) == Array(repeating: 0xC3, count: 64))
            }
        }
    }

    @Test("invalid operation returns max and leaves the buffer unchanged")
    func invalidOperation() {
        withBuffer(fill: 0xD4) { buffer in
            UserMemory.validationOverride = { _, _, _ in true }
            var frame = Arch.TrapFrame()
            frame.x0 = UInt64.max - 1
            frame.x2 = UInt64(UInt(bitPattern: buffer))
            ProcStatsSyscall.handle(frame: &frame, context: unusedContext())
            #expect(frame.x0 == UInt64.max)
            #expect(bytes(buffer) == Array(repeating: 0xD4, count: 64))
        }
    }

    private func processFrame(
        cursor: PID = 0,
        buffer: UnsafeMutableRawPointer
    ) -> Arch.TrapFrame {
        var frame = Arch.TrapFrame()
        frame.x0 = StatsSubOperation.processOperation.rawValue
        frame.x1 = cursor
        frame.x2 = UInt64(UInt(bitPattern: buffer))
        frame.x3 = UInt64(authorityHandle)
        return frame
    }

    private func unusedContext() -> SyscallContext {
        SyscallContext(
            processManager: UnsafeMutablePointer<ProcessManager>(bitPattern: 1)!,
            scheduler: UnsafeMutablePointer<KernelScheduler>(bitPattern: 1)!,
            ipc: UnsafeMutablePointer<KernelIPC>(bitPattern: 1)!,
            ppm: UnsafeMutablePointer<KernelPPM>(bitPattern: 1)!
        )
    }

    /// Runs `body` over a process that is registered in the stats index, holds the
    /// profiler capability at `authorityHandle` and is the running process.
    ///
    /// What this syscall hands out is the process table, names, pids, cpu time and
    /// footprint included, so it answers to `profileStats` on a `profileControl`
    /// target and to nothing weaker. The metadata block is what carries the caps
    /// table, and `makeProcess` leaves the field nil, so it is attached here.
    private func withAuthorizedProcess(
        pid   : PID,
        _ body: (UnsafeMutablePointer<Process>) -> Void
    ) {
        withProcesses([pid], resettingStatsIndex: true) { processes in
            let process = processes[0]
            #expect(ProcessManager.registerForProcStats(process))

            let metadata = attachMetadata(to: process)
            defer { destroyMetadata(of: process) }

            let outcome = metadata.pointee.capsTable.install(
                at: authorityHandle,
                Capability(
                    target: .profileControl,
                    badge : 0,
                    rights: [.profileStats]
                )
            )
            #expect(outcome.installed)
            #expect(outcome.displaced == nil)

            withCurrentProcess(process) { body(process) }

            UserMemory.validationOverride = nil
        }
    }

    private func withBuffer(
        fill: UInt8,
        _ body: (UnsafeMutableRawPointer) -> Void
    ) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        buffer.initializeMemory(as: UInt8.self, repeating: fill, count: 64)
        body(buffer)
        UserMemory.validationOverride = nil
        buffer.deallocate()
    }

    private func bytes(_ buffer: UnsafeMutableRawPointer) -> [UInt8] {
        Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: 64))
    }
}
