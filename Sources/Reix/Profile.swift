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
      arg: UInt64 = 0
) -> Bool {
    _syscall(.profileControl, op.rawValue, arg) == 0
}

/// Asks the kernel to dump the current profiler samples to the console.
@inline(__always)
public func profileDump() {
    profileControl(.dumpConsole)
}
