//
//  IrqWaitSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `irqWait(handle) -> bits` syscall provider.
///
/// Answers the set of lines that have fired since the last call, as bits over
/// the holder's own line list, and parks the caller when none have. `UInt64.max`
/// is the failure, which no bit pattern of a real answer can be: a set holds at
/// most eight lines.
///
/// Holding the capability *is* the authority, with no right consulted beyond
/// it. Splitting "may wait" from "may ack" would name two halves of one act:
/// nothing can service a device with one and not the other, and the delegation
/// controls that do matter, `grant` and `derive`, are already generic.
public struct IrqWaitSyscall: SyscallProvider {

    public static let number: SyscallNumber = .irqWait

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let set     = InterruptAuthority.resolve(
                  handle : frame.pointee.x0,
                  of     : current
              )
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        if set.pointee.pending != 0 {
            frame.pointee.x0   = UInt64(set.pointee.pending)
            set.pointee.pending = 0

            return
        }

        guard set.pointee.waiter == nil else {
            frame.pointee.x0 = UInt64.max
            return
        }

        set.pointee.waiter = current

        do {
            try context.scheduler.pointee.block(current.pointee.pid)

        } catch {
            set.pointee.waiter = nil
            frame.pointee.x0   = UInt64.max

            return
        }

        YieldSyscall.handle(frame: frame, context: context)
    }
}
