//
//  LaunchDeadline.swift
//  ReixOS
//

/// The instant a launch has to be finished by, on the virtual counter.
///
/// Fixed once, when the request is accepted, and never moved: every wait the
/// launch makes is a wait until this, not a fresh patience per step. Also the
/// schedule of the server's sweep, which is a deadline like any other.
public struct LaunchDeadline: Equatable {
    public let counter: UInt64

    /// `nil` when `frequency` cannot express `milliseconds`: below a kilohertz,
    /// or a span past half the counter, where the comparison below stops meaning anything.
    public init?(from now: UInt64, milliseconds: UInt64, frequency: UInt64) {
        let perMillisecond = frequency / 1000
        guard perMillisecond > 0 else { return nil }
        let (span, overflowed) = perMillisecond.multipliedReportingOverflow(by: milliseconds)
        guard !overflowed, span <= UInt64(Int64.max) else { return nil }
        counter = now &+ span
    }

    /// Wrapping subtraction read as signed, so a counter that went round is not a deadline already passed.
    public func reached(at now: UInt64) -> Bool { Int64(bitPattern: now &- counter) >= 0 }
}
