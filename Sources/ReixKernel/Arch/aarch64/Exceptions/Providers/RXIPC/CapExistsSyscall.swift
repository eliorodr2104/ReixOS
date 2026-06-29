//
//  CapExistsSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

/// `capExists(handle)` syscall provider. Writes `1` into `x0` when the current
/// process holds a capability at `handle`, `0` otherwise. Lets userland probe
/// which boot slots were seeded at spawn time without assuming a fixed layout.

public struct CapExistsSyscall: SyscallProvider {

    public static let number: SyscallNumber = .capExists

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)

        if let current = Arch.CPU.getCurrentProcess(),
           current.pointee.metadata.pointee.capsTable.resolve(handle) != nil {
            frame.pointee.x0 = 1

        } else { frame.pointee.x0 = 0 }
    }
}
