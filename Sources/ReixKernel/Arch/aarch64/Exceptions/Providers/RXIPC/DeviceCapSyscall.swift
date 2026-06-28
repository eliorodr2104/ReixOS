//
//  DeviceCapSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

/// `deviceCap()` syscall provider. Writes the handle of the bootstrap
/// device cap shared  into `x0`, as recorded by the kernel at
/// spawn time. Returns `UInt32.max` when the process has no parent channel
/// (no current process, or none was seeded), so userland can map it to `nil`.

public struct DeviceCapSyscall: SyscallProvider {

    public static let number: SyscallNumber = .deviceCap

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        if let current = Arch.CPU.getCurrentProcess(),
           let parentDeviceCap = current.pointee.metadata.pointee.deviceCap {
            frame.pointee.x0 = UInt64(parentDeviceCap)

        } else { frame.pointee.x0 = UInt64(UInt32.max) }
    }
}
