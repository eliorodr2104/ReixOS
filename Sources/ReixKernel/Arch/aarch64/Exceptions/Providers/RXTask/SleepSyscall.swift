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
/// next ready task. Deadlines live in a table here instead of on
/// `Process` because a sleeper is already linked into a scheduler queue
/// through its own `prev`/`next`: a second intrusive list over the same
/// nodes would corrupt both.
public struct SleepSyscall: SyscallProvider {

    public static let number: SyscallNumber = .sleep

    /// One parked sleeper.
    ///
    /// `deadline == 0` marks a free slot: PID 0 is the init process and
    /// therefore a real key, while a deadline of zero is unreachable
    /// because a sleeper is only ever parked with a positive tick count.
    private struct Sleeper {
        var pid     : PID    = 0
        var deadline: UInt64 = 0
    }

    private static var sleepers = InlineArray<32, Sleeper>(repeating: Sleeper())

    /// Earliest armed deadline, so the tick can bail out on two loads.
    private static var earliest: UInt64 = .max
    private static var parked  : Int    = 0

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

        let (deadline, overflowed) = context.scheduler.pointee.systemTicks
            .addingReportingOverflow(ticks)

        guard !overflowed else {
            frame.pointee.x0 = 1
            return
        }

        guard park(
            pid     : current.pointee.pid,
            deadline: deadline
        ) else {
            frame.pointee.x0 = 1
            return
        }

        do {
            try context.scheduler.pointee.block(current.pointee.pid)
        } catch {
            unpark(pid: current.pointee.pid)
            frame.pointee.x0 = 1
            return
        }

        frame.pointee.x0 = 0

        YieldSyscall.handle(frame: frame, context: context)
    }

    /// Readies every sleeper whose deadline has come.
    ///
    /// Driven from the timer tick, so the common path has to be cheap:
    /// with nobody parked it is a load, a compare and a return, and the
    /// table is only walked on the tick that actually owes a wake-up.
    public static func wakeExpired(at now: UInt64) {
        guard parked > 0, earliest <= now else { return }

        var survivingEarliest: UInt64 = .max

        for i in 0..<sleepers.count {
            let sleeper = sleepers[i]

            guard sleeper.deadline != 0 else { continue }

            guard sleeper.deadline <= now else {
                survivingEarliest = min(survivingEarliest, sleeper.deadline)
                continue
            }

            sleepers[i].deadline = 0
            parked -= 1
            
            try? Kernel.scheduler.pointee.wakeUp(sleeper.pid)
        }

        earliest = survivingEarliest
    }


    private static func park(
        pid     : PID,
        deadline: UInt64
    ) -> Bool {
        for i in 0..<sleepers.count where sleepers[i].deadline == 0 {
            sleepers[i] = Sleeper(pid: pid, deadline: deadline)
            parked  += 1
            earliest = min(earliest, deadline)

            return true
        }

        return false
    }


    /// Gives back the slot `pid` holds, if it holds one.
    ///
    /// Reached from the failed-block path above and from
    /// `ProcessManager.killProcess`, which is what keeps a process that dies
    /// while parked from taking its slot to the grave. A pid with no slot is
    /// not an error here, so a death route may call this unconditionally
    /// without first asking whether the process was sleeping.
    public static func unpark(pid: PID) {
        for i in 0..<sleepers.count
        where sleepers[i].deadline != 0 && sleepers[i].pid == pid {
            sleepers[i].deadline = 0
            parked -= 1

            return
        }
    }
}
