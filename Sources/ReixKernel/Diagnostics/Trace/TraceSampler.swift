//
//  TraceSampler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// Statistical PC sampling, riding the one periodic interrupt the kernel
/// already takes.
///
/// A sample is the interrupted `ELR` and `x30` filed as an ordinary trace
/// record, and the profile is the histogram a host builds from a few thousand
/// of them. That is the whole mechanism: nothing is instrumented, nothing is
/// bracketed, and the cost is one record per tick instead of one per event.
/// What it buys over the `syscallExit` spans is coverage of the code nobody
/// thought to measure, which in an unfamiliar kernel is where the time is.
///
/// Off unless asked for, twice over. `TraceSampling`'s bit is clear in the
/// default `Trace.runtimeMask`, so a machine nobody profiles pays one load, one
/// `tst` and a branch per tick, and `TraceSampling.isEnabled` can take even
/// that out of the image. The bit is what `profileControl(.enable, mask)`
/// moves; `setSampleDivider` only decides how often a recording sampler fires.
enum TraceSampler {

    /// Frames of the interrupted kernel chain one sample may walk.
    ///
    /// Four, because a sample is a leaf plus enough context to attribute it,
    /// and because the ring holds 256 records: at five records per tick a
    /// 100 Hz sampler would evict its own oldest samples twice a second and
    /// leave no room for the syscall and IPC events they are read against.
    static let frameLimit = 4

    /// Ticks between samples. One means every tick, which is the default.
    private static var divider: UInt64 = 1

    /// Recording ticks left before the next sample.
    ///
    /// Counted down only while the class is recording, so a divider means
    /// "one sample every N ticks of sampling" and not "of uptime". A run that
    /// is switched on halfway through therefore fires on its first tick rather
    /// than at whatever phase the counter happened to be left in.
    private static var countdown: UInt64 = 1


    // MARK: - Control

    /// Sets the tick divider, rejecting zero.
    ///
    /// Zero is refused rather than clamped: `profileControl` op 4 has one
    /// failure value and a caller asking for a rate of nothing has made a
    /// mistake that silently becoming "every tick" would hide from it.
    ///
    /// The countdown restarts here, so a divider raised mid-run takes effect
    /// from the next tick instead of after the tail of the old interval.
    static func setDivider(_ ticks: UInt64) -> Bool {
        guard ticks >= 1 else { return false }

        divider   = ticks
        countdown = ticks

        return true
    }


    // MARK: - Tick path

    /// The tick's whole sampling obligation, gate included.
    ///
    /// Inlined so the gate is what the tick handler actually contains: with
    /// the class masked off this is a load of `runtimeMask`, a `tst` and a
    /// branch, and with `TraceSampling.isEnabled` false it is nothing at all.
    /// Everything past the gate is out of line in `take`, which keeps the
    /// firing path's register pressure and its code out of the tick.
    @inline(__always)
    static func onTick(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        guard TraceSampling.isEnabled                    else { return }
        guard Trace.runtimeMask & TraceSampling.bit != 0 else { return }

        countdown &-= 1

        guard countdown == 0 else { return }

        countdown = divider

        take(frame: frame)
    }


    /// Files one sample, plus the kernel frames beneath it when there are any.
    ///
    /// `info` bit 0 carries the exception level, read from `SPSR.M[3:0]`: the
    /// mode field is zero exactly for `EL0t`, so anything else was the kernel.
    /// The host needs it because the two halves of a profile are not comparable
    /// otherwise, an EL1 address being a kernel symbol and an EL0 one being an
    /// offset in whichever process `pid` names.
    @inline(never)
    private static func take(frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        let interruptedEL1 = frame.pointee.spsr & 0xF != 0

        Trace.emit(
            TraceSampling.self,
            code: TraceCode.sample,
            info: interruptedEL1 ? 1 : 0,
            a   : frame.pointee.elr,
            b   : frame.pointee.x30
        )

        guard interruptedEL1 else { return }

        walkKernelChain(from: frame.pointee.x29)
    }


    /// Emits up to `frameLimit` `sampleFrame` records for the chain at `fp`.
    ///
    /// EL1 only, and the check above is not a filter but the safety property.
    /// A user `x29` is a value the process chooses, so following it from EL1
    /// reads through a translation an unprivileged program controls, and the
    /// fault that a bad one raises lands in the kernel rather than in the
    /// program that asked for it. There is nothing to gain by risking it: a
    /// user sample already carries PC and LR, and a host with the process image
    /// can unwind the rest offline.
    ///
    /// Only the first frame is checked for being the kernel's. After that the
    /// monotonic rule in `FrameWalker` keeps the walk climbing one stack, and
    /// four frames is a short enough leash that a chain corrupt enough to leave
    /// it is already a panic waiting on the next kernel access.
    @inline(__always)
    private static func walkKernelChain(from fp: UInt64) {
        guard isKernelFrame(fp) else { return }

        var depth: UInt16 = 0

        FrameWalker.walk(from: fp, limit: frameLimit) { returnAddress in
            depth &+= 1

            Trace.emit(
                TraceSampling.self,
                code: TraceCode.sampleFrame,
                info: depth,
                a   : returnAddress
            )

            return true
        }
    }


    /// `FrameWalker`'s plausibility test, plus the half the address must be in.
    ///
    /// User space is confined to `L0[1..255]` and the kernel owns everything
    /// outside that window, both the identity-mapped image at the bottom and
    /// the linear map at the top, so one range test names every address this
    /// walk is allowed to dereference.
    @inline(__always)
    private static func isKernelFrame(_ framePointer: UInt64) -> Bool {
        FrameWalker.isPlausible(framePointer)
            && (framePointer <  UserSpaceLayout.userMin
             || framePointer >= UserSpaceLayout.userMax)
    }
}
