//
//  ProfileControlSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

import ReixABI

/// `profileControl(op, arg)` syscall provider: the only door into the trace
/// ring from user space.
///
/// `x0` = `ProfileOperation` raw, `x1` = the operation's argument. Writes `0`
/// on success and `1` on failure, an operation number this kernel does not know
/// included. A single failure value is deliberate: nothing about a profiler
/// control needs to be distinguishable, and the caller that gets `1` back has
/// exactly one thing to do about it either way.
///
/// `pmuProbe` is the one exception, and the only op whose `x0` is a value
/// rather than a status: it answers with the count of programmable event
/// counters. No count is reserved as an error because a probe cannot fail, and
/// zero is a real answer meaning the block was never initialized.
///
/// This is not a privileged syscall. The ring holds pids, syscall numbers and
/// durations, which is a real side channel between processes, and closing it is
/// an entitlement question that belongs with the rest of them rather than a
/// check bolted on here.
public struct ProfileControlSyscall: SyscallProvider {

    public static let number: SyscallNumber = .profileControl

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let operation = ProfileOperation(rawValue: frame.pointee.x0) else {
            frame.pointee.x0 = 1
            return
        }

        let argument = frame.pointee.x1

        switch operation {

            case .disable:
                Trace.runtimeMask = 0
                frame.pointee.x0  = 0

            // A zero argument means every class, so the common case is not
            // spelled `UInt32.max` by every caller that just wants tracing on.
            case .enable:
                Trace.runtimeMask = argument == 0
                                  ? UInt32.max
                                  : UInt32(truncatingIfNeeded: argument)

                frame.pointee.x0 = 0

            case .reset:
                TraceRing.reset()
                frame.pointee.x0 = 0

            case .dumpConsole:
                TraceDump.toConsole(processManager: context.processManager)
                frame.pointee.x0 = 0

            case .setSampleDivider:
                frame.pointee.x0 = TraceSampler.setDivider(argument) ? 0 : 1

            case .attachExport:
                frame.pointee.x0 = attachExport(
                    handle : UInt32(truncatingIfNeeded: argument),
                    context: context
                ) ? 0 : 1

            case .pmuProbe:
                frame.pointee.x0 = Arch.PMU.probe()
        }
    }


    /// Resolves `handle` against the caller's table and hands the region it
    /// names to `TraceExport`.
    ///
    /// Handle resolution is `ShmMap`'s, deliberately: the export region is an
    /// ordinary `shmCreate` region and the capability is the only thing that
    /// says who may offer one. `.read` and `.write` are both required, because
    /// the kernel writes these pages and the caller reads them, and a caller
    /// holding less than that is asking the kernel for a window it could not
    /// have mapped itself.
    ///
    /// Two pages is the floor: page 0 is the stats snapshot and the event ring
    /// needs at least one page after it.
    private static func attachExport(
        handle : UInt32,
        context: SyscallContext
    ) -> Bool {
        guard let current = Arch.CPU.getCurrentProcess(),
              let cap     = current.pointee.metadata.pointee.capsTable.resolve(handle),
              case .shared(let region) = cap.target,
              cap.rights.contains([.read, .write])
        else { return false }

        let pageCount = region.pointee.pageCount
        guard pageCount >= 2 else { return false }

        let physical = region.pointee.physicalPage.address
        guard physical <= VirtualMemoryManager.maxPhysicalAddress else { return false }

        guard let base = UnsafeMutableRawPointer(
            bitPattern: UInt(physical + VirtualMemoryManager.physicalOffset)
        ) else { return false }

        return TraceExport.attach(
            base          : base,
            pageCount     : pageCount,
            scheduler     : context.scheduler,
            ppm           : context.ppm,
            processManager: context.processManager
        )
    }
}
