//
//  DeriveSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/06/2026.
//

import ReixABI

/// `derive(handle:session:rights:)` syscall provider. Mints a new capability to
/// the same endpoint bound to a caller-chosen *session* with reduced rights,
/// gated by the `.derive` right on the source cap and by the set-once-from-zero
/// rule in `CapsTable.mint`.
///
/// A session is all a caller can choose here: identity comes from
/// `Process.identity` and is stamped by the kernel at delivery, so this syscall
/// cannot be used to speak as somebody else.
///
/// `x0` = handle, `x1` = session, `x2` = rights. Writes the new handle into
/// `x0`, or `UInt32.max` on failure (missing `.derive`, already-badged source,
/// bad handle, table full).
public struct DeriveSyscall: SyscallProvider {

    public static let number: SyscallNumber = .derive

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        let handle  = UInt32(truncatingIfNeeded: frame.pointee.x0)
        let session = Badge(truncatingIfNeeded: frame.pointee.x1)
        let rights  = CapRights(rawValue: UInt16(truncatingIfNeeded: frame.pointee.x2))

        guard let newHandle = current.pointee.metadata.pointee.capsTable.mint(
            from   : handle,
            session: session,
            rights : rights

        ) else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        // The new capability, not the one it was cut from. Both keep the target
        // alive so the reference count cannot tell them apart, but the rights
        // differ, and `release` will be handed this one when it goes: a derive
        // that retained the source counted a receiver the derived capability
        // does not have.
        if let minted = current.pointee.metadata.pointee.capsTable.resolve(newHandle) {
            context.ipc.pointee.retain(minted)
        }

        frame.pointee.x0 = UInt64(newHandle)
    }
}
