//
//  PreemptionRegion.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/08/2026.
//

/// Whether a region may only shorten interrupt latency, or may also give the
/// CPU up in the middle of the operation and be finished on a later entry.
///
/// `.latencyOnly` is the contract this framework started with: the checkpoint
/// opens the window so a pending interrupt is serviced, the tick sets
/// `needsResched`, and the operation still runs to completion on the frame it
/// started on. `.rescheduling` adds one thing on top of it: the driver may
/// *abandon* the operation at a checkpoint and hand the half-stepped state back,
/// for the caller to park and for the syscall to be re-executed later. That is
/// seL4's continuation model, and it is chosen over Linux's because switching
/// tasks on the kernel stack demands one kernel stack per process, 4096 bytes
/// here, against the 56 bytes a parked `RangeRetirement` costs.
///
/// ## Why the region carries this and not the driver
///
/// Because it is not a statement about how badly the latency is wanted, it is a
/// statement about whether anybody is left to restart. `AddressSpaceTeardown`
/// runs only from the two process-death paths in `ProcessManager`: there is no
/// live process to park state on and no syscall to re-enter, so a driver-side
/// flag saying "reschedule where you can" would park a continuation on a corpse.
/// The answer differs per operation and never per call site, which is exactly
/// what a static requirement on the region says and a parameter does not.
///
/// It also has to fold, for this file's reasons. Read through the region's
/// generic parameter it is a `static let` of a concrete type in every
/// specialization, so a `.latencyOnly` region keeps today's code with no branch
/// and no scheduler read; a driver argument passed by value would put both back.
public enum PreemptionMode {

    /// The window is opened, the operation always finishes.
    case latencyOnly

    /// The window is opened, and a reschedule pending after it may abandon the
    /// operation at that checkpoint.
    case rescheduling
}


/// Which long operation is running, and therefore which policy applies to it.
///
/// One conforming type per operation the kernel is allowed to open the
/// interrupt window inside. It is deliberately not a `Loggable` category: a log
/// tag says who printed a line, this says which span of kernel time a
/// measurement belongs to, and the same type will name that span in the trace
/// ring later. `slot` is the index of the region's slot in `PreemptionSpans`,
/// so the regions number contiguously from zero and nothing renumbers them.
///
/// ## Why static requirements and not an enum value
///
/// The framework promises that a region switched off leaves nothing behind: no
/// counter read, no barrier, no tag in the image. That promise is a constant
/// fold, and a fold needs the region to be known where `Preemption.run` is
/// compiled.
///
/// As an `enum` passed by value it was known only where the inliner agreed to
/// inline `run` into the caller. It declined in `munmapRegion`, because that
/// function is large, and both retirement sites then shared one specialization
/// that took the region in a register, derived `stepsPerProbe` with a `csinc`
/// and kept all three tags in `.rodata`. Nothing at either call site said so,
/// and the region switched off still paid for every checkpoint.
///
/// As a generic parameter the fold is structural. Embedded Swift specializes
/// every generic call, so `run` over `RegionUnmap` and `run` over
/// `RegionDecommit` are different functions whatever the inliner decides about
/// either, and within each one `isEnabled` and `policy` are `static let`s of a
/// single concrete type: constants, with no branch left to fold. This is
/// `Loggable`'s shape and it holds for `Loggable`'s reason.
///
/// Static only, again like `Loggable`. `any PreemptionRegion` would erase the
/// type, put every requirement behind a witness table and destroy the fold
/// exactly as the runtime value did. This kernel has no existential anywhere;
/// do not introduce one here.
public protocol PreemptionRegion {

    /// Index of this region's slot in `PreemptionSpans`.
    ///
    /// Distinct per region and inside the table, which `PreemptionSpans` checks
    /// rather than trusts: the table is sized by hand and the two are only kept
    /// in step by whoever adds a region.
    static var slot: Int { get }

    /// Fixed origin tag for the span, six characters like a log tag so a
    /// future trace dump lines up with the boot log.
    ///
    /// Read from `PreemptionSpans.merge` and nowhere else, which is what makes
    /// it the marker for whether a disabled region compiled away: the literal
    /// reaches the image only through that one specialization, and that
    /// specialization is unreachable when `isEnabled` is `false`. Verified on
    /// `"[CLON]"`, which stayed absent from the linked kernel for as long as
    /// `AddressSpaceClone` had no call site and appeared once it gained one.
    static var name: StaticString { get }

    /// Whether `Preemption.run` may open the interrupt window in this region.
    ///
    /// Switching one to `false` is how a region that turns out to have an
    /// unsafe step boundary is retired: the operation keeps running, step by
    /// step, with the machinery folded out of the loop entirely.
    static var isEnabled: Bool { get }

    /// Whether a checkpoint here may also abandon the operation, or may only
    /// service the interrupt and carry on.
    ///
    /// See `PreemptionMode`. `.rescheduling` is not something a region earns by
    /// being long: it obliges the caller to park what `Preemption.run` gives back
    /// and to get the rest of the work done on a later entry, so it is only
    /// available to an operation whose caller can honour both.
    static var mode: PreemptionMode { get }

    /// How often this region is willing to be interrupted, and what it costs
    /// to ask.
    static var policy: CheckpointPolicy { get }
}


/// `VMAManager.cloneRegions`, one batch of up to 32 pages per step, and the
/// whole clone in one run.
///
/// One run and not one per region, for the reason `teardown` takes one: the
/// budget restarts at every `Preemption.run` and `longestStretch` is per run, so
/// a run per region would report the longest region and hide the sum of them.
/// Measured on the retirement side, 256 one-batch runs reported 72 µs while the
/// door had really been shut for 18 to 21 ms. `RegionClone` therefore walks the
/// parent's whole VMA list itself.
///
/// ## Why the step is a batch of pages and not a region
///
/// A step that cloned a whole region would copy or write-protect every committed
/// page of it, thousands of them, and no probe interval rescues a step that big:
/// the window stays shut for `budget` plus the steps between two probes, so
/// probing *less* often makes the overshoot worse and only a smaller step makes
/// it better. The step is bounded in pages and the interval is one, exactly as
/// the three retirement regions are and for their reason.
///
/// The 2 MiB leaf-table span the walk is already structured by is not a usable
/// step on its own: 512 pages at the ~2 µs a cloned page costs is about 1 ms,
/// five times the budget. It survives as the *cap* on a batch, because a batch
/// reads one leaf table and may not cross into the next.
///
/// ## The policy
///
/// A cloned page is a `retain`, a `mapUserPage` into the child and, in the
/// copy-on-write case, a second one that rewrites the parent's own descriptor:
/// two three-level descents and two `dsb ishst`, with no TLB maintenance at all,
/// which is the same order of work as the 2.06 µs a retirement page was measured
/// at (a descent, a descriptor clear, a `tlbi`, a `dsb` and a frame release). So
/// 32 pages is ~64 µs against a 200 µs budget, and probing every step puts one
/// batch of overshoot on top of it, ~264 µs, the profile the retirement regions
/// were proven at.
///
/// The estimate has room: 32 pages stay inside the budget for anything up to
/// 6.25 µs a page, three times the measured retirement cost. The occasional step
/// that also allocates and zeroes a page table, for a 2 MiB span the child does
/// not have one for yet, adds a few µs to one step in sixteen.
///
/// ## Why it is not `.rescheduling`, three times over
///
/// `split` is not restartable. Level 2 restarts a syscall by rewinding `ELR_EL1`
/// by 4 onto the `svc`, and the prefix of `SplitProcessSyscall` before
/// `cloneRegions` calls `spawnProcess`, which allocates a `Process`, its
/// metadata, an address space and a `VMAManager`, then copies the metadata
/// fields and clones the capability table. Re-executing the syscall would run all
/// of that again and spawn a second child.
///
/// Parking the child `Process` alongside the operation would not fix that, it
/// would move the leak. A parent killed while parked leaves that child in no
/// scheduler queue, with `family.parent` still `nil` because it is assigned only
/// after `cloneRegions` returns, and with nothing able to reap it: a `Process`,
/// an address space and a cloned capability table, unreachable for the rest of
/// the boot.
///
/// Third, `cloneRegions` flushes the TLB once, at the end. The parent's own
/// descriptors are downgraded to read-only as the walk proceeds while its TLB
/// still holds writable entries for those same pages, and that is harmless only
/// because nothing runs at EL0 between a checkpoint and the end of the syscall.
/// Suspending would let the parent run against a TLB that still permits the
/// writes its page tables have stopped permitting.
///
/// What is *not* a reason is the one this doc used to give. A half-cloned address
/// space is indeed a state no other task may interact with, and none can:
/// `addTask(childProcess)` runs only after `cloneRegions` returns, so the child
/// sits in no queue and is not runnable for the whole clone.
public enum AddressSpaceClone: PreemptionRegion {

    public static let slot     : Int              = 0
    public static let name     : StaticString     = "[CLON]"
    public static let isEnabled: Bool             = true
    public static let mode     : PreemptionMode   = .latencyOnly
    public static let policy   : CheckpointPolicy = CheckpointPolicy(stepsPerProbe: 1, budget: 200)
}


/// `VMAManager.munmapRegion` phase 3, one batch of up to 32 pages per step.
///
/// The dense case over the mmap window is the longest operation in the kernel,
/// about 110,000 pages, and the reason this framework exists.
///
/// `.rescheduling`, which it became by having the bookkeeping that used to follow
/// the run folded into the operation. While the unlink and the `kfree` of every
/// covered VMA node still sat in a loop after `Preemption.run`, a suspension
/// would have skipped that tail and left an address space describing regions
/// whose pages are gone, ready to fault a page back into one of them.
/// `UnmapRetirement` now frees each node in the step that finishes its pages, so
/// `.completed` means the syscall is genuinely done and a suspension leaves only
/// nodes whose pages are still there to be retired on the way back.
public enum RegionUnmap: PreemptionRegion {

    public static let slot     : Int              = 1
    public static let name     : StaticString     = "[UNMP]"
    public static let isEnabled: Bool             = true
    public static let mode     : PreemptionMode   = .rescheduling
    public static let policy   : CheckpointPolicy = CheckpointPolicy(stepsPerProbe: 1, budget: 200)
}


/// `VMAManager.rollbackMapping`, the same operation as `RegionUnmap` reached from
/// a mapping path that is already unwinding.
///
/// `mapRegion` and `ShmCreate` undo a half-built mapping by unmapping the range
/// they had just registered, and both discard the result with `try?`. A
/// suspension there is not a latency question but a lost one: the outcome saying
/// "come back and finish" would be thrown away with the error, the syscall would
/// return a failure and never be re-entered, and the user would keep a live
/// read/write window onto frames already handed back to the buddy allocator.
///
/// So the rollback gets its own region rather than a rule about how to call the
/// other one. `mode` is a `static let` of a concrete type, so this
/// specialization of `Preemption.run` folds the level-2 branch out completely:
/// the scheduler is never read, `.suspended` is never constructed, and the park
/// the caller would have written is unreachable code the optimizer drops.
/// Suspension is absent from the emitted rollback path instead of merely being
/// unlikely in it.
///
/// The policy is `RegionUnmap`'s, because the work per step is the same work.
public enum RegionUnmapRollback: PreemptionRegion {

    public static let slot     : Int              = 4
    public static let name     : StaticString     = "[RBCK]"
    public static let isEnabled: Bool             = true
    public static let mode     : PreemptionMode   = .latencyOnly
    public static let policy   : CheckpointPolicy = CheckpointPolicy(stepsPerProbe: 1, budget: 200)
}


/// `VMAManager.decommit` pass B, one batch of up to 32 pages per step.
///
/// Same operation as the unmap and the same cost per page: retire the
/// translation, then release the frame.
///
/// `.rescheduling`, and it qualifies because its `Preemption.run` is the last
/// statement of `decommit`: there is no tail for a suspension to skip, and every
/// VMA stays registered either way, which is the whole point of decommitting
/// rather than unmapping. So the state a suspension leaves visible is a range
/// some of whose lazily backed pages are gone, which is a state `decommit` is
/// allowed to produce on purpose.
///
/// It was the first region converted and the one the mechanism was proven on,
/// which is why `RangeRetirement` is written to leave the list alone: it is
/// shared with `decommit`, where dropping a reservation would turn the syscall
/// into a `munmap`. `RegionUnmap` therefore drives a separate operation.
public enum RegionDecommit: PreemptionRegion {

    public static let slot     : Int              = 2
    public static let name     : StaticString     = "[DCMT]"
    public static let isEnabled: Bool             = true
    public static let mode     : PreemptionMode   = .rescheduling
    public static let policy   : CheckpointPolicy = CheckpointPolicy(stepsPerProbe: 1, budget: 200)
}


/// `VMAManager.teardown`, one batch of up to 32 pages per step.
///
/// Every region of a dying address space in one run, so the budget spans the
/// whole teardown rather than restarting at each region. The page cost is the
/// two regions above, and so is the policy.
///
/// `.latencyOnly`, and this one is a hard constraint rather than a preference.
/// `teardown` is reached only from `ProcessManager.releaseAddressSpace` and
/// `destroyPartialAddressSpace`, both process-death paths, so there is no live
/// process to park a continuation on and no syscall to re-execute to finish it:
/// suspending would park state on something that is being freed, and would leave
/// the frames of a dead address space owned by nobody. This is the reason
/// `PreemptionMode` is a property of the region at all.
public enum AddressSpaceTeardown: PreemptionRegion {

    public static let slot     : Int              = 3
    public static let name     : StaticString     = "[TDWN]"
    public static let isEnabled: Bool             = true
    public static let mode     : PreemptionMode   = .latencyOnly
    public static let policy   : CheckpointPolicy = CheckpointPolicy(stepsPerProbe: 1, budget: 200)
}


/// When the driver stops to let interrupts in.
///
/// ## The budget, and why it is time and not a step count
///
/// A step count alone bounds nothing: the same 16 steps are 16 page unmaps in
/// one region and 16 whole region copies in another. What has to be bounded
/// is the *time* the window stays shut, because that is the interrupt latency
/// the operation adds. So the driver reads the counter and compares elapsed
/// time against `budget`.
///
/// 200 µs, against a 10 ms tick: an interrupt that arrives at the worst
/// possible moment is serviced a fiftieth of a tick late, so timekeeping
/// drifts by at most 2% while the operation runs and no tick is ever lost
/// (the timer is rearmed by its own handler, so a handler that runs late
/// pushes the whole schedule out rather than queueing). It is also some three
/// orders of magnitude above a checkpoint, measured at ~240 ns on QEMU virt,
/// which is what holds the machinery to a tenth of a percent.
///
/// ## The probe interval, and why the budget alone is not enough
///
/// Reading the counter is not free: `Arch.Timer.counter()` leads with an
/// `isb`, which is the point of it, and measures ~70 ns here. Paying that per
/// page would be a real tax on the very operations this is meant to help, so
/// the time is read every `stepsPerProbe` steps and the cost divided by that
/// many.
///
/// The interval trades that overhead against overshoot. The steps between two
/// probes cannot be interrupted, so the window stays shut for `budget` plus
/// `stepsPerProbe` steps, and that product has to be small next to the budget.
/// Measured with a synthetic 0.67 µs step and 16 steps per probe, the longest
/// the window stayed shut was 232 µs against a 200 µs budget, so the model
/// holds. The correction the model then demands is that a large step wants a
/// small interval, which is why every region here probes every single step.
///
/// ## Why every region probes every step
///
/// A retirement step is one batch of up to 32 pages, and a page retire is a page
/// table walk, a descriptor clear, a `tlbi`, a `dsb` and a frame release:
/// measured at 2.06 µs per resident page on QEMU virt, so 66 µs a batch. At the
/// 16 steps this framework started with that is 1056 µs of overshoot on a 200 µs
/// budget, and the window was observed shut for 1116 µs, which is the model
/// being right rather than the policy being right. At one step per probe the
/// same operation overshoots by one batch and the ~70 ns counter read costs
/// 0.1% of the step it guards. There is nothing left to buy by probing less
/// often: `stepsPerProbe` above one is for steps far cheaper than a probe.
///
/// A teardown's steps are not all that expensive, because the last step of a
/// region retires whatever is left of it and a one-page region is one 2.06 µs
/// step. The interval is sized for the expensive end all the same: the cheap end
/// pays 3.4% for a probe it does not need, while an interval large enough to
/// amortize it would put four full batches between two checkpoints and overshoot
/// the budget by 272 µs on the dense case.
///
/// A clone step is 32 pages of comparable cost and lands in the same place. It
/// is worth reading `AddressSpaceClone` for the arithmetic all the same, because
/// that region is where the interval was first argued backwards: its step used to
/// be a whole region, and a step too large is fixed by shrinking the step and
/// made worse by probing less often.
public struct CheckpointPolicy {

    /// Steps between two readings of the counter.
    let stepsPerProbe: UInt32

    /// Microseconds of uninterrupted work allowed before the window opens.
    let budget: UInt32


    /// The budget in counter units, for the machine actually running.
    ///
    /// Converted once per `Preemption.run` from `CNTFRQ_EL0` rather than
    /// baked in, because 62.5 MHz is a fact about QEMU virt and not about
    /// AArch64. `&*` cannot wrap for any plausible pair: the product only
    /// reaches 2^64 at a terahertz counter.
    @inline(__always)
    func counterUnits(at frequency: UInt64) -> UInt64 {
        UInt64(budget) &* frequency / 1_000_000
    }
}
