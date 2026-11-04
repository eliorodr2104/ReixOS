//
//  IrqWaitSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `irqWait(handle, ticks) -> bits` syscall provider.
///
/// Answers the set of lines that have fired since the last call, as bits over
/// the holder's own line list, and parks the caller when none have. `UInt64.max`
/// is the failure, which no bit pattern of a real answer can be: a set holds at
/// most eight lines.
///
/// `ticks` of zero waits for as long as it takes, which is right for a driver
/// whose device is known to be alive and wrong for every other case. Anything
/// else is a deadline, and the wait comes back with **zero** when it passes:
/// zero is not a real answer either, because a wake with no line set does not
/// happen. A driver that gets it knows its device has stopped answering and can
/// do something about it - which, before there was a deadline, it could not.
/// One wedged device used to park its driver for the rest of the boot, and
/// everything that needed that driver with it.
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

        let ticks = frame.pointee.x1

        set.pointee.waiter = current

        if ticks != 0 {
            guard KernelDeadlineQueue.shared.arm(
                current,
                kind    : .irq,
                deadline: context.scheduler.pointee.systemTicks &+ ticks
            ) else {
                // No room to promise a deadline is not the same as promising one
                // and breaking it. Refusing here leaves the caller awake and
                // able to try again, rather than parked on a promise nobody kept.
                set.pointee.waiter = nil
                frame.pointee.x0   = UInt64.max

                return
            }
        }

        do {
            try context.scheduler.pointee.block(current.pointee.pid)

        } catch {
            cancelDeadline(on: current)
            set.pointee.waiter = nil
            frame.pointee.x0   = UInt64.max

            return
        }

        YieldSyscall.handle(frame: frame, context: context)
    }


    /// Wakes a driver whose device did not answer in time.
    ///
    /// Zero lines, which is the answer no real wake can give. The set is let go
    /// of on the way out: a waiter that is no longer waiting must not be left in
    /// the field a later interrupt writes through.
    static func expire(_ process: UnsafeMutablePointer<Process>) {

        if let set = InterruptClaims.set(waitedOnBy: process) {
            set.pointee.waiter = nil
        }

        process.pointee.context?.pointee.x0 = 0

        Kernel.scheduler.pointee.resume(process)
    }


    /// Takes back a deadline this syscall armed, and only one it armed.
    @inline(__always)
    static func cancelDeadline(on process: UnsafeMutablePointer<Process>) {
        guard process.pointee.kernelDeadlineKind == .irq else { return }
        _ = KernelDeadlineQueue.shared.cancel(process)
    }
}
