//
//  MunmapSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//


import ReixABI

/// `munmap(addr, size)` syscall provider.
///
/// Releases the pages of `[addr, addr + size)`. The range need not match an
/// `mmap` exactly: it may cover part of a region, span several of them, and
/// unmapped holes inside it are skipped. `addr` must be page-aligned and
/// `size` rounds up to the page.
/// 
/// Returns `0` on success or `UInt64.max` on failure, an unaligned address, a range outside user space, or one with
/// nothing mapped in it at all.
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
