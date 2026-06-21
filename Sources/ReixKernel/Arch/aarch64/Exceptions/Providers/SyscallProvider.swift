//
//  SyscallProvider.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Contract every syscall implementation must satisfy.
///
/// Providers are stateless static structs in their own file under
/// `Arch/aarch64/Syscall/Providers/`. The dispatcher in
/// `SyscallHandler.handle(type:frame:)` resolves the concrete type
/// from the `SyscallNumber` via a single compile-time switch, so the
/// protocol is consumed only as a shared shape — no existential
/// indirection is involved.
import ReixABI

public protocol SyscallProvider {
    static var  number: SyscallNumber { get }
    static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    )
}
