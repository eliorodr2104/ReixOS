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
/// on success and `1` on failure, which includes both an operation number this
/// kernel does not know and one it knows but has not implemented yet. A single
/// failure value is deliberate: nothing about a profiler control needs to be
/// distinguishable, and the caller that gets `1` back has exactly one thing to
/// do about it either way.
///
/// Ops 4 to 6 (`setSampleDivider`, `attachExport`, `pmuProbe`) are named in the
/// ABI and reserved for later phases. They answer `1` rather than being absent
/// from the switch, so adding one later is a change here and not a change to
/// the ABI userland was built against.
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
                TraceDump.toConsole()
                frame.pointee.x0 = 0

            case .setSampleDivider, .attachExport, .pmuProbe:
                frame.pointee.x0 = 1
        }
    }
}
