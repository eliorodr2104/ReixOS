//
//  MunmapSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `munmap(addr, size)` syscall provider.
///
/// Releases a region previously returned by `mmap`. In this milestone
/// only full-region unmap is supported: `addr` must match the VMA start
/// and `size` must match the VMA size. Returns `0` on success or
/// `UInt64.max` on failure.
import ReixABI

public struct MunmapSyscall: SyscallProvider {

    public static let number: SyscallNumber = .munmap

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        let addr       = frame.pointee.x0
        let size       = frame.pointee.x1

        guard let current    = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        do {
            try vmaManager.pointee.munmapRegion(
                addr: addr,
                size: size
            )
            frame.pointee.x0 = 0

        } catch {
            frame.pointee.x0 = UInt64.max
        }
    }
}
