//
//  HardwareTimer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


public protocol HardwareTimerInterface {

    /// Rearm the per-core tick.
    static func rearm()

    /// Free-running monotonic counter, in architectural ticks.
    ///
    /// Ordered against the surrounding instruction stream, so a pair of reads
    /// really does bracket the work between them.
    static func counter() -> UInt64

    /// The same counter, unordered.
    ///
    /// For stamps that are only ever read, never differenced: they do not pay
    /// for the barrier `counter()` needs.
    static func counterUnordered() -> UInt64

    /// Frequency of `counter()`, in Hz.
    static func frequency() -> UInt64
}
