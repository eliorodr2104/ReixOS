//
//  MmapSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `mmap(size)` syscall provider.
///
/// Reserves an anonymous read/write region in the mmap area. Backing
/// pages are not allocated here: the page-fault handler materialises
/// them lazily. Returns the base address of the new region, or `0` on
/// failure (no aligned gap, invalid size).
import ReixABI

public struct MmapSyscall: SyscallProvider {

    public static let number: SyscallNumber = .mmap

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        let requestedSize = frame.pointee.x0

        guard let current    = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            frame.pointee.x0 = 0
            return
        }

        do {
            let mapped = try vmaManager.pointee.mmapAnonymous(
                size       : requestedSize,
                permissions: [.read, .write, .user]
            )
            frame.pointee.x0 = mapped

        } catch {
            frame.pointee.x0 = 0
        }
    }
}
