//
//  IdentityAliveSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// `identityAlive(badge)` syscall provider. Writes `1` into `x0` when a process
/// with that identity is still running, `0` otherwise.
///
/// Why a query and not a notification. Every userland server keeps a fixed table
/// of per-client state keyed on the identity the kernel stamps into each message,
/// and nothing ever told it a client had died, so those slots were held for the
/// rest of the boot. A message on an endpoint would be prompter, and would also
/// need somewhere to queue a death that arrives while the server is not in
/// `receive` - and a death notification that can be dropped leaves exactly the
/// leak it was built to close. This cannot be dropped, because there is nothing
/// to drop: the answer is a fact about now, asked for at the moment it matters.
///
/// Ambient, like `getPid` and `clockNow`, and for the same reason: the answer is
/// one bit about an opaque counter the caller already had to be *sent* a message
/// to learn. It names nothing, reaches nothing, and grants nothing.
public struct IdentityAliveSyscall: SyscallProvider {

    public static let number: SyscallNumber = .identityAlive

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let identity = Badge(truncatingIfNeeded: frame.pointee.x0)

        frame.pointee.x0 = context.processManager.pointee.isAlive(identity: identity) ? 1 : 0
    }
}
