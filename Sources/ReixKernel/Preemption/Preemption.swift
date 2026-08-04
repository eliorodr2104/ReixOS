//
//  Preemption.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/08/2026.
//

/// What became of the operation `Preemption.run` was handed.
///
/// ## Why the operation comes back instead of the driver keeping it
///
/// The driver knows about steps and about the clock, and deliberately nothing
/// about processes or address spaces. Parking a continuation means knowing where
/// it may safely be stored and what invalidates it, and only the caller knows
/// that: `VMAManager` parks its retirement on itself, keyed to the range it
/// validated, and drops it when it tears the address space down. A table inside
/// `Preemption` would have to be told all of it, and would become a second owner
/// of state the caller already owns.
///
/// The payload is the half-stepped operation itself, by value, which is the whole
/// economy of this design: 56 bytes for a `RangeRetirement` against the 4096-byte
/// per-process kernel stack that switching tasks mid-operation would demand, and
/// this kernel targets 4 MB devices.
public enum PreemptionOutcome<Operation: ResumableOperation> {

    /// Every step ran. There is nothing left to finish and nothing to park.
    case completed

    /// A checkpoint found a reschedule pending and stopped there. The operation
    /// carries the steps it had taken and no more, so finishing the work means
    /// running it again later.
    case suspended(Operation)
}


/// The one driver for every `ResumableOperation`, and the only place in the
/// kernel that unmasks interrupts at EL1.
///
/// ## What it is for
///
/// The vectors mask IRQs on entry and nothing at EL1 unmasks them, so the
/// duration of a syscall is the interrupt latency it inflicts. Measured over
/// 2.86 million exception entries, not one was taken at EL1 outside the idle
/// loop. That is a correctness-friendly place to have started from and a
/// terrible latency story: a dense `munmap` over the mmap window is about
/// 110,000 pages of work with the door shut.
///
/// This driver steps such an operation and, on a schedule set by
/// `CheckpointPolicy`, briefly opens the door. It does **not** switch tasks.
/// A tick arriving in the window sets `needsResched` and the switch happens
/// where it always happens, at the tail of `swift_exception_handler` on the
/// outermost frame, once the syscall has finished and unwound. So the
/// operation always runs to completion on the stack it started on, which is
/// why no per-process kernel stack is needed for any of this.
///
/// A `.rescheduling` region goes one step further: at a checkpoint it may
/// abandon the operation and hand the unfinished state back, for the caller to
/// park and the syscall to be re-executed later. That is still not a task switch
/// here, it is a return, and the switch still happens at that same tail. See
/// `PreemptionMode` for why the two levels are a property of the region.
///
/// ## Why the operation has to be a state machine
///
/// See `ResumableOperation`. The short version: a closure-scoped region could
/// only promise the window is *closed again* afterwards, never that the point
/// it opened at was safe. Steps promise that structurally, and this is the
/// only way to run one, so there is no path that opens a window anywhere but
/// between two steps.
///
/// ## What the caller owes
///
/// The window is a real exception at EL1: the timer handler runs, rearms,
/// walks the sleeper and IPC deadline lists and drains the log ring. Anything
/// that handler touches must therefore be consistent when `run` is called,
/// not merely when the operation's own state is. In practice that means: call
/// it from a syscall or fault path that has finished whatever it was doing to
/// the scheduler queues, and never from inside an open log record. The second
/// one is cheap to check, so the driver checks it rather than trusting it.
public enum Preemption {

    /// Drivers currently on the stack.
    ///
    /// Only the outermost one opens windows. Without this, an operation whose
    /// step drives a second operation, a teardown stepping over regions and
    /// unmapping each one page at a time, would have the inner driver opening
    /// a window *inside* an outer step, which is exactly the guarantee the
    /// step boundary exists to give.
    ///
    /// It is counted unconditionally, even for a region with the window
    /// switched off, because a disabled outer region still has to suppress an
    /// enabled inner one. That is the one thing a disabled region still pays:
    /// an increment and a decrement per *run*, plus the `swift_beginAccess`
    /// every static var in this kernel is accessed through. No barrier, no
    /// counter read, no call into the measurement, and nothing per step.
    private static var activeDrivers: UInt32 = 0


    /// Runs `operation`, opening the interrupt window between steps whenever the
    /// region's budget has been spent, and in a `.rescheduling` region stopping
    /// early if one of those windows let a reschedule request in.
    ///
    /// The region is a generic parameter, so `Region.isEnabled` and
    /// `Region.policy` are constants in every specialization of this function
    /// and a region that is switched off leaves nothing here but the step loop.
    /// It arrives as a metatype only because there is no syntax for binding a
    /// function's generic parameters explicitly: the region has to be inferred
    /// from an argument, and a thin metatype of a concrete type is a value
    /// specialization erases entirely. See `PreemptionRegion` for why this
    /// replaced an enum passed by value.
    ///
    /// Still `@inline(__always)`, which is now an optimization and not the
    /// mechanism: the fold happens in the specialization whether the inliner
    /// accepts or declines.
    ///
    /// ## Where the suspend decision sits, and why exactly there
    ///
    /// After `openWindow` returns, because that window is the only point in this
    /// function where an interrupt can be taken, so `needsResched` read anywhere
    /// earlier would be a question about somebody else's tick, one this operation
    /// did not let in and has no business acting on.
    ///
    /// Suspending only stops. It switches nothing: `needsResched` is still set,
    /// so `performPendingSwitch` does the switch where it always does, on the
    /// outermost frame after the syscall has returned and unwound. Switching from
    /// here would abandon a Swift frame `eret` cannot come back to, and would need
    /// the per-process kernel stack this design exists to avoid.
    ///
    /// Only the outermost driver can reach the decision, since `owner` is false
    /// for a nested one, so an inner operation is never suspended out from under
    /// the step driving it and the region on top decides for the whole nest.
    ///
    /// The measurement is merged by the `defer` and so covers this exit too: a
    /// partial run held the door shut for real and has to report it.
    ///
    /// - Parameters:
    ///   - region: names the policy, the mode and the measurement slot.
    ///   - operation: consumed, because a half-stepped operation is not a
    ///     thing a caller should be able to hold on to.
    ///
    /// - Returns: `.completed`, or `.suspended` carrying the steps not taken,
    ///   which only a `.rescheduling` region can ever produce.
    @inline(__always)
    public static func run<Region: PreemptionRegion, Operation: ResumableOperation>(
        _  region   : Region.Type,
        _  operation: consuming Operation
    ) throws(Operation.Failure) -> PreemptionOutcome<Operation> {

        let policy = Region.policy

        activeDrivers &+= 1

        let owner = Region.isEnabled && activeDrivers == 1

        var work           = operation
        var budget         : UInt64 = 0
        var openedAt       : UInt64 = 0
        var sinceProbe     : UInt32 = 0
        var longestStretch : UInt64 = 0
        var longestWindow  : UInt64 = 0
        var cheapestWindow : UInt64 = .max
        var checkpoints    : UInt64 = 0

        if owner {
            budget   = policy.counterUnits(at: Arch.Timer.frequency())
            openedAt = Arch.Timer.counter()
        }

        // Runs on the throwing exit too, so a failed operation still reports
        // the latency it cost before it gave up.
        defer {
            activeDrivers &-= 1

            if owner {
                let tail = Arch.Timer.counter() &- openedAt

                PreemptionSpans.merge(
                    Region.self,
                    stretch       : tail > longestStretch ? tail : longestStretch,
                    longestWindow : longestWindow,
                    cheapestWindow: cheapestWindow,
                    checkpoints   : checkpoints
                )
            }
        }

        while true {
            guard case .more = try work.step() else { return .completed }

            guard owner else { continue }

            sinceProbe &+= 1

            guard sinceProbe >= policy.stepsPerProbe else { continue }

            sinceProbe = 0

            let now     = Arch.Timer.counter()
            let stretch = now &- openedAt

            guard stretch >= budget else { continue }

            // The tick handler drains the log ring, and a record left half
            // written would be spliced into by that drain.
            guard !LogRing.isRecording else { continue }

            if stretch > longestStretch { longestStretch = stretch }

            openedAt = openWindow()

            let serviced = openedAt &- now

            if serviced > longestWindow  { longestWindow  = serviced }
            if serviced < cheapestWindow { cheapestWindow = serviced }

            checkpoints &+= 1

            // Folds away entirely for a `.latencyOnly` region: `mode` is a
            // `static let` of a concrete type in this specialization.
            guard case .rescheduling = Region.mode else { continue }

            guard Kernel.scheduler.pointee.needsResched else { continue }

            return .suspended(work)
        }
    }


    /// Lets whatever is pending in, and returns the reading that starts the
    /// next uninterrupted stretch.
    ///
    /// `daifclr #3` unmasks FIQ along with IRQ. That is safe here rather than
    /// merely tolerable: GICv2 is configured Group 1, so it only ever signals
    /// IRQ, and no other source in this machine raises an FIQ. Should one ever
    /// appear it lands in `fiq_invalid` and panics, which is the correct
    /// outcome for an interrupt this kernel has no handler for.
    ///
    /// The barrier between the two writes is what makes this a window rather
    /// than a pair of writes. An `MSR` to `DAIF` is not context-synchronizing,
    /// so without it the unmask need not have taken effect before the remask
    /// two instructions later, and no interrupt is ever taken.
    ///
    /// It is called for itself, not borrowed from something else that happens
    /// to contain an `isb`. Depending on a barrier hidden inside a counter read
    /// would leave preemption working only until someone optimised that read,
    /// and it would break silently.
    ///
    /// The reading taken *after* the remask is the one returned, so the time
    /// spent servicing an interrupt is charged to the window and not to the
    /// operation's next stretch.
    @inline(__always)
    private static func openWindow() -> UInt64 {
        Arch.CPU.enableInterrupts()

        Arch.CPU.instructionBarrier()

        Arch.CPU.disableInterrupts()

        return Arch.Timer.counter()
    }
}
