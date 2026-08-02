//
//  DecommitSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI

/// `decommit(addr, size)` syscall provider.
///
/// Releases the frames behind an anonymous range while keeping the VMA
/// reserved, so the pages fault back in zero-filled where the region is
/// lazily backed. The range is fully validated by `VMAManager.decommit` page-aligned start,
/// inside the user window, and every VMA it overlaps anonymous.
/// Returns `0` on success or `UInt64.max` on failure, like the other memory providers.
public struct DecommitSyscall: SyscallProvider {

    public static let number: SyscallNumber = .decommit

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        let addr = frame.pointee.x0
        let size = frame.pointee.x1

        guard let current    = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        do {
            try vmaManager.pointee.decommit(
                addr: addr,
                size: size
            )
            frame.pointee.x0 = 0

        } catch {
            frame.pointee.x0 = UInt64.max
        }
    }
}
