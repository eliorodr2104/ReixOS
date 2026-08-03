//
//  VirtualTimerInterruptHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Drives preemptive scheduling on every Virtual Timer tick.
///
/// On each tick the handler snapshots the running process context into
/// the process trap frame, rearms the core timer (`ect`), signals
/// end-of-interrupt to the GIC and asks the scheduler if the quantum
/// has expired.
///
/// When it has, the handler only *asks* for a switch. It never performs one,
/// because the frame it was handed may be a nested one taken at EL1, in the
/// middle of a syscall, and overwriting that with another task's user context
/// would `eret` away from a half-finished kernel call: its Swift frame, its
/// locals and its return address would be orphaned on the kernel stack and
/// the syscall would never return a value. The switch is carried out by
/// `swift_exception_handler`, at the one point where the kernel stack is
/// known to have unwound.
public struct VirtualTimerInterruptHandler: InterruptHandler {

    public static let id: UInt32 = 27

    public static func handle(frame: UnsafeMutablePointer<Arch.TrapFrame>) {        
        snapshotCurrentContext(frame: frame)

        AArch64VirtualTimer.ect()
        Kernel.gic.pointee.endOfInterrupt(id: id)

        let quantumExpired = Kernel.scheduler.pointee.onTick()

        let systemTicks = Kernel.scheduler.pointee.systemTicks

        SleepSyscall.wakeExpired(at: systemTicks)

        if Kernel.ipc.pointee.hasDeadlineDue(at: systemTicks) {
            Kernel.ipc.pointee.checkTimeouts(now: systemTicks)
        }

        // The one periodic path already holding the CPU with IRQs masked, which is
        // what `LogRing` needs; bounded by the UART being slower than the tick.
        LogSink.drain(budget: LogSink.tickBudget)

        guard quantumExpired else { return }

        Kernel.scheduler.pointee.requestReschedule()
    }


    /// Refreshes the running task's saved user context from `frame`.
    ///
    /// Only a frame taken from EL0 describes user state. A nested frame taken
    /// at EL1 holds kernel state, an `elr` pointing into kernel code and an
    /// `spsr` reading EL1h, so letting it reach `context` would leave the task
    /// scheduled to resume inside the kernel at a stale address, on whatever
    /// stack the interrupted handler happened to be using. Such a frame is
    /// dropped here: the switch site re-reads the real user frame later.
    private static func snapshotCurrentContext(
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        guard frame.pointee.spsr & 0xF == 0 else {
            return
        }

        guard let current = Arch.CPU.getCurrentProcess() else {
            return
        }

        current.pointee.context?.pointee = frame.pointee
    }
}
