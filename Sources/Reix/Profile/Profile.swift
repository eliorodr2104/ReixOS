//
//  Profile.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

import ReixABI

/// Zero-alloc wrapper over the `profileControl` syscall.
/// Returns `true` when the kernel replies with x0 == 0.
@inline(__always)
@discardableResult
public func profileControl(
    _ op : ProfileOperation,
      authority: UInt32,
      arg: UInt64 = 0
) -> Bool {
    _syscall(.profileControl, op.rawValue, arg, UInt64(authority)) == 0
}


/// Asks the kernel to dump the current profiler samples to the console.
@inline(__always)
public func profileDump(authority: UInt32) {
    profileControl(.dumpConsole, authority: authority)
}


/// Fills `stats` with the kernel's machine-wide counters.
/// Returns `true` when the kernel replies with x0 == 0.
///
/// `authority` is a profiler capability handle carrying `.profileStats`, the
/// same one `profileAttachExport` takes. A process without one gets nothing.
@inline(__always)
@discardableResult
public func systemStats(
    into stats: inout SystemStats,
    authority : UInt32
) -> Bool {
    withUnsafeMutablePointer(to: &stats) { ptr in
        _syscall(
            .procStats,
            StatsSubOperation.systemOperation.rawValue,
            0,
            UInt64(UInt(bitPattern: ptr)),
            UInt64(authority)
        ) == 0
    }
}


/// Walks the live process table one process at a time.
/// The kernel returns the live process with the smallest
/// pid strictly greater than `after`, or `UInt64.max` once the sweep is done.
///
/// A fresh sweep starts with `after: 0`; each following call passes the pid
/// this one returned, not `after + 1`, since pids are not contiguous once a
/// process has been reaped.
///
/// A caller whose `authority` does not carry `.profileStats` is answered
/// `UInt64.max`, which reads as a sweep that ended before it began.
@inline(__always)
public func nextProcessStats(
    after pid : UInt64,
    into stats: inout ProcessStats,
    authority : UInt32
) -> UInt64 {
    withUnsafeMutablePointer(to: &stats) { ptr in
        _syscall(
            .procStats,
            StatsSubOperation.processOperation.rawValue,
            pid,
            UInt64(UInt(bitPattern: ptr)),
            UInt64(authority)
        )
    }
}

/// Hands the kernel the SHM handle to export live profiler state into.
/// See `Top.swift` for the exported layout.
@inline(__always)
@discardableResult
public func profileAttachExport(handle: UInt32, authority: UInt32) -> Bool {
    profileControl(.attachExport, authority: authority, arg: UInt64(handle))
}
