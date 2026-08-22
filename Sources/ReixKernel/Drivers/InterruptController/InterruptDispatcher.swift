//
//  InterruptDispatcher.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Routes acknowledged interrupts to the right `InterruptHandler`.
///
/// The router is intentionally a single static switch instead of a
/// dynamic table: handlers are stateless static structs, so resolving
/// `id → concrete type` is a compile-time match. Adding a new device
/// means registering one extra case here next to the new handler file.
/// Unknown IDs are surfaced as warnings so a spurious IRQ does not
/// silently disappear.
///
/// End-of-interrupt is signalled here rather than inside each handler,
/// because the value `GICC_EOIR` needs is the whole acknowledged word and
/// this is the last place that still holds it. A handler only ever knew the
/// INTID it was registered for, which is the same thing for a PPI or an SPI
/// and one field short for an SGI.
public struct InterruptDispatcher {

    private init() {}

    public static func dispatch(
        ack  : UInt32,
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        switch GIC.intid(of: ack) {
            case VirtualTimerInterruptHandler.id:
                VirtualTimerInterruptHandler.handle(frame: frame)

            default:
                if !deliverToHolder(line: GIC.intid(of: ack)) {
                    warnSpurious(id: GIC.intid(of: ack))
                }
        }

        Kernel.gic.pointee.endOfInterrupt(ack: ack)
    }

    /// Hands `line` to the userland holder that claimed it, if there is one.
    ///
    /// Masks first and wakes second, in that order and never the reverse. A
    /// level-triggered device holds its line up until its driver services the
    /// device itself, so returning to userland with the line still armed re-enters
    /// this handler at once and the machine stops making progress. `irqAck` is
    /// what lifts the mask, after the holder has actually touched the device.
    ///
    /// A line that fires with nobody parked on it is not lost: the bit stays in
    /// `pending` and the next `irqWait` collects it without blocking.
    private static func deliverToHolder(line: UInt32) -> Bool {
        guard let set = InterruptClaims.owner(of: line),
              let bit = set.pointee.bit(of: line)
        else { return false }

        Kernel.gic.pointee.disableInterrupt(id: line)

        set.pointee.masked  |= bit
        set.pointee.pending |= bit

        guard let waiter = set.pointee.waiter else { return true }

        // The value the parked `irqWait` returns, written where every blocked
        // syscall's answer is written. Collected here rather than left for the
        // waiter to read, so the bits cannot be overwritten by a second line
        // firing between the wake and the return.
        waiter.pointee.context?.pointee.x0 = UInt64(set.pointee.pending)

        set.pointee.pending = 0
        set.pointee.waiter  = nil

        Kernel.scheduler.pointee.resume(waiter)

        return true
    }


    private static func warnSpurious(id: UInt32) {
        
        guard id < GIC.reservedInterruptBase else { return }

        // Tagged `[GIC ]`, not with a tag of the router's own: the line reports
        // an INTID the controller presented, not one the dispatcher invented.
        GIC.warning("spurious IRQ id=\(id)")
    }
}
