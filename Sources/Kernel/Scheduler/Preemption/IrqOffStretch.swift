//
//  IrqOffStretch.swift
//  ReixOS
//

import ReixABI

/// The longest stretches the kernel ran with IRQs masked, per path.
///
/// Every exception runs masked from the vector to the `eret`, so how long it
/// takes is interrupt latency inflicted on everything else. `PreemptionSpans`
/// already measures inside the regions; this measures the whole exception,
/// which is what an interrupt actually waits behind: the prologue a region does
/// not cover, every syscall no region exists for, and interrupt handlers too.
///
/// One stretch is open at a time. An exception opens it at entry and closes it
/// at exit, and a `Preemption` window closes it before unmasking and reopens it
/// after, so time spent with the door open is never charged as masked. An
/// interrupt taken inside that window opens and closes a stretch of its own,
/// which is why the reopen restores the path it was handed instead of trusting
/// whatever the nested exception left in the static.
///
/// A stretch that ends in the idle loop never reaches the exception's exit, so
/// the two sites that enter it close the stretch themselves.
///
/// Stamped with the unordered counter read: these are whole exceptions, tens of
/// microseconds and up, and an `isb` on every entry and exit of every exception
/// would be the most expensive thing about measuring them.
enum IrqOffStretch {

    private static var since: UInt64 = 0
    private static var path : UInt16 = 0

    /// Per path, the longest stretch so far, saturated. Kept so a trace record
    /// is filed only when a path's own worst case grows, which is rare after
    /// boot, instead of on every exception.
    private static var longestPerPath = InlineArray<66, UInt32>(repeating: 0)

    /// The longest stretch on any path, and the path that ran it.
    private(set) static var longest    : UInt64 = 0
    private(set) static var longestPath: UInt16 = 0


    /// The path an exception belongs to, read off its frame at entry, before a
    /// switch can replace the registers it is read from.
    @inline(__always)
    static func path(
        of    type : ExceptionType,
        frame      : UnsafeMutablePointer<Arch.TrapFrame>
    ) -> UInt16 {
        guard case .synchronous = type else {
            return UInt16(IrqOffPath.interrupt)
        }

        let isSyscall = (frame.pointee.esr >> 26) & 0x3F == 0x15
        let number    = frame.pointee.x8

        guard isSyscall, number < UInt64(IrqOffPath.syscallLimit) else {
            return UInt16(IrqOffPath.otherException)
        }

        return UInt16(number)
    }


    @inline(__always)
    static func open(path: UInt16, at now: UInt64) {
        self.since = now
        self.path  = path
    }


    /// How long the open stretch has run at `now`, or `fallback` when none is
    /// open. `Preemption.run` decides its windows on this, so a budget counts
    /// every masked microsecond and not only the ones its own run spent.
    @inline(__always)
    static func elapsed(at now: UInt64, orElse fallback: UInt64) -> UInt64 {
        guard since != 0, now > since else { return fallback }

        return now - since
    }


    /// Ends the open stretch and returns its path so a window can reopen it,
    /// or returns `nil` when no stretch was open: a driver run outside any
    /// exception, at boot, has nothing to split.
    @inline(__always)
    @discardableResult
    static func close(at now: UInt64) -> UInt16? {
        guard since != 0 else { return nil }

        let stretch = now > since ? now - since : 0
        since = 0

        fold(stretch, path: path)

        return path
    }


    /// Folds one closed stretch into the maxima. A path index past the table
    /// cannot be produced by `path(of:frame:)` and is dropped, not trusted.
    static func fold(_ stretch: UInt64, path: UInt16) {
        if stretch > longest {
            longest     = stretch
            longestPath = path
        }

        let index = Int(path)

        guard index < longestPerPath.count else { return }

        let saturated = UInt32(min(stretch, UInt64(UInt32.max)))

        guard saturated > longestPerPath[index] else { return }

        longestPerPath[index] = saturated

        Trace.emit(
            TracePreemption.self,
            code: TraceCode.irqOff,
            info: path,
            a   : stretch
        )
    }


    /// One bounded value copy for a dump whose interrupt windows can update
    /// the live maxima while the transcript is being formatted.
    static func snapshot() -> InlineArray<66, UInt32> { longestPerPath }

    /// The longest stretch recorded for one exception path.
    static func longest(onPath path: UInt16) -> UInt32 {
        Int(path) < longestPerPath.count ? longestPerPath[Int(path)] : 0
    }

    #if !hasFeature(Embedded)
    /// Host suites share these statics; each starts from zero.
    static func reset() {
        since          = 0
        path           = 0
        longest        = 0
        longestPath    = 0
        longestPerPath = InlineArray<66, UInt32>(repeating: 0)
    }
    #endif
}
