//
//  SleepSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

import ReixABI

/// `sleep(ticks)` syscall provider.
///
/// Parks the caller in the scheduler `waiting` queue until the system
/// tick counter reaches an absolute deadline, then hands the CPU to the
/// next ready task.
public struct SleepSyscall: SyscallProvider {

    public static let number: SyscallNumber = .sleep
    private static var index = SleepDeadlineIndex()

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess() else {
            frame.pointee.x0 = 1
            return
        }

        let ticks = frame.pointee.x0

        guard ticks > 0 else {
            frame.pointee.x0 = 0
            YieldSyscall.handle(frame: frame, context: context)
            return
        }

        guard ticks <= UInt64(Int64.max) else {
            frame.pointee.x0 = 1
            return
        }

        guard park(
            current,
            deadline: context.scheduler.pointee.systemTicks &+ ticks
        ) else {
            frame.pointee.x0 = 1
            return
        }

        do {
            try context.scheduler.pointee.block(current.pointee.pid)
        } catch {
            unpark(current)
            frame.pointee.x0 = 1
            return
        }

        frame.pointee.x0 = 0

        YieldSyscall.handle(frame: frame, context: context)
    }

    private static func park(
        _ process: UnsafeMutablePointer<Process>,
        deadline: UInt64
    ) -> Bool {
        guard index.insert(process) else { return false }

        guard KernelDeadlineQueue.shared.arm(
            process,
            kind: .sleep,
            deadline: deadline
        ) else {
            _ = index.remove(pid: process.pointee.pid)
            return false
        }

        return true
    }


    /// Gives back the slot `pid` holds, if it holds one.
    ///
    /// Reached from the failed-block path above and from
    /// `ProcessManager.killProcess`, which is what keeps a process that dies
    /// while parked from taking its slot to the grave. A pid with no slot is
    /// not an error here, so a death route may call this unconditionally
    /// without first asking whether the process was sleeping.
    public static func unpark(pid: PID) {
        guard let process = index.remove(pid: pid) else { return }
        _ = KernelDeadlineQueue.shared.cancel(process)
    }

    private static func unpark(_ process: UnsafeMutablePointer<Process>) {
        guard process.pointee.kernelDeadlineKind == .sleep else { return }
        _ = index.remove(pid: process.pointee.pid)
        _ = KernelDeadlineQueue.shared.cancel(process)
    }

    static func expire(_ process: UnsafeMutablePointer<Process>) {
        _ = index.remove(pid: process.pointee.pid)
        guard case .waiting = process.pointee.status else { return }
        Kernel.scheduler.pointee.resume(process)
    }
}
