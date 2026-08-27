//
//  WallClock.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// What time the machine thinks it is.
///
/// There is no battery-backed clock in this design and no network to ask, so
/// the machine boots not knowing the date and somebody has to tell it. Until
/// somebody does, every reading is `Time.unknown`, which is zero, which is not
/// a date. That is deliberate: a machine that guesses the time writes wrong
/// dates into files and they outlive the guess.
///
/// What the machine *does* have is a counter that only goes forward. Setting
/// the clock records one instant and the counter reading at that moment; every
/// reading afterwards is that instant plus how far the counter has moved. So
/// the wall clock inherits the counter's monotonicity: it cannot go backwards
/// unless somebody sets it backwards, and that takes a capability.
public enum WallClock {

    /// The instant the clock was last set to, and the counter then.
    nonisolated(unsafe) private static var baseNanos  : UInt64 = 0
    nonisolated(unsafe) private static var baseCounter: UInt64 = 0
    nonisolated(unsafe) private static var known      : Bool   = false


    /// Records what time it is now.
    public static func set(nanoseconds: UInt64) {
        baseNanos   = nanoseconds
        baseCounter = Arch.Timer.counter()
        known       = nanoseconds != 0
    }


    /// What time it is, or zero when nobody has said.
    public static func now() -> UInt64 {
        guard known else { return 0 }

        return baseNanos &+ elapsedNanos(since: baseCounter)
    }


    /// Nanoseconds the counter has advanced since `mark`.
    ///
    /// Split into whole seconds and a remainder before scaling, because the
    /// obvious `delta * 1_000_000_000 / frequency` overflows a 64-bit word
    /// after about five minutes at this machine's counter rate.
    static func elapsedNanos(since mark: UInt64) -> UInt64 {

        let frequency = Arch.Timer.frequency()
        guard frequency > 0 else { return 0 }

        let now   = Arch.Timer.counter()
        let delta = now > mark ? now - mark : 0

        let seconds   = delta / frequency
        let remainder = delta % frequency

        return seconds &* 1_000_000_000
            &+ (remainder &* 1_000_000_000) / frequency
    }
}
