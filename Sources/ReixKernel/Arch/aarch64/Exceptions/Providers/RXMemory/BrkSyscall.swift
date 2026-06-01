//
//  BrkSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `brk(newBreak)` syscall provider.
///
/// When `newBreak == 0` returns the current program break (query
/// mode). Otherwise asks the VMA manager to extend the brk VMA up to
/// the requested address. Returns the resulting break, or
/// `UInt64.max` on failure.
public struct BrkSyscall: SyscallProvider {

    public static let number: SyscallNumber = .brk

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        let requested  = frame.pointee.x0
        guard let current    = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager,
              let metadata   = current.pointee.metadata
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        if requested == 0 {
            frame.pointee.x0 = vmaManager.pointee.programBreak()
            return
        }

        do {
            let newBreak = try vmaManager.pointee.extendBreak(to: requested)
            metadata.pointee.programBreak = newBreak
            frame.pointee.x0              = newBreak

        } catch {
            frame.pointee.x0 = UInt64.max
        }
    }
}
