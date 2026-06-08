//
//  DeriveSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/06/2026.
//

/// `derive(handle:badge:rights:)` syscall provider. Derives a new capability
/// to the same endpoint with a fresh badge and reduced rights, gated by the
/// `.derive` right on the source cap. Writes the new handle into `x0`, or
/// `UInt32.max` on failure (missing `.derive`, bad handle, table full).
public struct DeriveSyscall: SyscallProvider {

    public static let number: SyscallNumber = .derive

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        guard let current = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)
        let badge  = Badge(truncatingIfNeeded: frame.pointee.x1)
        let rights = CapRights(rawValue: UInt8(truncatingIfNeeded: frame.pointee.x2))

        guard let newHandle = current.pointee.metadata.pointee.capsTable.derive(
            from : handle,
            badge: badge,
            rights: rights
        ) else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        frame.pointee.x0 = UInt64(newHandle)
    }
}
