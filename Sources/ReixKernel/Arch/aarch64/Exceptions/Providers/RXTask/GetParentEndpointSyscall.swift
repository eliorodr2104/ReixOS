//
//  GetParentEndpointSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/06/2026.
//

/// `parentEndpoint()` syscall provider. Writes the handle of the bootstrap
/// endpoint shared with the parent into `x0`, as recorded by the kernel at
/// spawn time. Returns `UInt32.max` when the process has no parent channel
/// (no current process, or none was seeded), so userland can map it to `nil`.
import ReixABI

public struct GetParentEndpointSyscall: SyscallProvider {

    public static let number: SyscallNumber = .parentEndpoint

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context

        if let current = Arch.CPU.getCurrentProcess(),
           let parentEndpoint = current.pointee.metadata.pointee.parentEndpoint {
            frame.pointee.x0 = UInt64(parentEndpoint)

        } else { frame.pointee.x0 = UInt64(UInt32.max) }
    }
}
