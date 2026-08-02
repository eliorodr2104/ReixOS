//
//  CapDropSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//

import ReixABI

/// `capDrop(handle)` syscall provider.
///
/// Gives one capability back and frees its slot. This is the counterpart the
/// grant path was missing: the kernel installs a granted cap into the receiver's
/// table while the sender is still inside `send`, so a server that rejects the
/// request has already been charged a slot it never wanted. `CapsTable` holds 16
/// entries, so without a way to return one, a client retrying in a loop can fill
/// a server's table from the outside and leave every later grant nowhere to land.
///
/// `x0` = handle. Writes `0` on success or `UInt64.max` on failure, like the
/// memory providers. A handle the caller does not hold is a failure and not a
/// silent success, so userland cannot read "dropped" into a stale handle.
public struct CapDropSyscall: SyscallProvider {

    public static let number: SyscallNumber = .capDrop

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = UInt64.max
            return
        }

        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)

        switch context.ipc.pointee.releaseCapability(handle, of: current) {
            case .success: frame.pointee.x0 = 0
            case .failure: frame.pointee.x0 = UInt64.max
        }
    }
}
