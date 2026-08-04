//
//  PreemptionSpan.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/08/2026.
//

/// What the driver learned about one region, accumulated over every run of it.
///
/// All durations are raw counter units, `CNTVCT_EL0` deltas: ~16 ns each on
/// QEMU virt, and `Arch.Timer.frequency()` is what turns them into time. They
/// are kept raw for the reason `LogSink` keeps its stamps raw, a division per
/// sample buys nothing, and because the trace ring these feed will want the
/// unconverted delta anyway.
public struct PreemptionSpan {

    /// The region's tag, copied on the first checkpoint so a dump does not
    /// have to map indices back to cases.
    public internal(set) var name: StaticString = ""

    /// The longest the window stayed shut, which is the interrupt latency
    /// this region actually cost. This is the number the whole framework
    /// exists to bound: it should sit near `CheckpointPolicy.budget` however
    /// long the operation runs.
    public internal(set) var longestStretch: UInt64 = 0

    /// The most time spent inside one open window.
    ///
    /// The evidence, not an overhead figure. A window with nothing pending
    /// costs a barrier and two counter reads; one that services a timer tick
    /// costs the whole handler. A value far above `cheapestWindow` is an
    /// interrupt having been taken at EL1 inside kernel work, which nothing
    /// in this kernel's history had done before this framework.
    public internal(set) var longestWindow: UInt64 = 0

    /// The least time spent inside one open window, which with nothing
    /// pending is one checkpoint.
    ///
    /// Expect zero, and do not read it as free. QEMU's virtual counter does
    /// not advance between two reads a few instructions apart, so a single
    /// checkpoint is below the resolution the guest has; timed in bulk it is
    /// ~240 ns. On hardware this becomes a real floor.
    public internal(set) var cheapestWindow: UInt64 = .max

    /// Windows opened in this region, all runs together.
    public internal(set) var checkpoints: UInt64 = 0

    /// Whether anything has ever been recorded here.
    public var isEmpty: Bool { checkpoints == 0 && longestStretch == 0 }


    public init() {}
}


/// The per-region measurement table.
///
/// A fixed array in `.bss`, one slot per `PreemptionRegion`, indexed by the
/// region's `slot`. It is deliberately the dumbest thing that answers the
/// question the framework has to answer, "did the window bound the latency",
/// and it is the input to the trace ring that replaces it later: a ring records
/// every span, this keeps the extremes.
///
/// Written from the driver's exit path, so at most once per run and never per
/// step, and read by whoever wants to report. No locking: the kernel is
/// single-core and the write happens with IRQs masked.
///
/// Both entry points are generic over the region for the reason the driver is:
/// the whole table access has to sit inside the part of `Preemption.run` that a
/// disabled region folds away, and a specialization per region is what lets it.
/// A single non-generic `merge` taking the region as a value would be emitted
/// with external linkage whether or not anything called it, and would drag the
/// index arithmetic and every region's tag into the image with it.
public enum PreemptionSpans {

    /// One slot per conformer of `PreemptionRegion`. Sized by hand because a
    /// generic value parameter needs a literal, and because nothing enumerates
    /// the conforming types; the accessors bounds-check `slot` rather than
    /// trusting the two to stay in step.
    private static var table = InlineArray<5, PreemptionSpan>(repeating: PreemptionSpan())


    public static func span<Region: PreemptionRegion>(of region: Region.Type) -> PreemptionSpan {
        guard Region.slot < table.count else { return PreemptionSpan() }

        return table[Region.slot]
    }


    /// Folds one completed run into the region's slot.
    ///
    /// Maxima rather than a history, and `checkpoints` a running total, so a
    /// caller reading the table after any number of runs still sees the worst
    /// latency the region ever cost.
    ///
    /// `Region.name` is read here rather than passed in because the region is
    /// now a type: this body is compiled once per region and mentions only that
    /// region's tag, so a switched-off region's literal has nothing left
    /// referencing it and the linker drops it.
    @inline(__always)
    static func merge<Region: PreemptionRegion>(
        _ region      : Region.Type,
        stretch       : UInt64,
        longestWindow : UInt64,
        cheapestWindow: UInt64,
        checkpoints   : UInt64
    ) {
        let index = Region.slot

        guard index < table.count else { return }

        table[index].name = Region.name

        if stretch        > table[index].longestStretch { table[index].longestStretch = stretch        }
        if longestWindow  > table[index].longestWindow  { table[index].longestWindow  = longestWindow  }
        if cheapestWindow < table[index].cheapestWindow { table[index].cheapestWindow = cheapestWindow }

        table[index].checkpoints &+= checkpoints
    }
}
