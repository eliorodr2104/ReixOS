//
//  Time.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// A point in time, as nanoseconds since the first instant of 1970.
///
/// One number and no time zone, because a machine has one clock and the places
/// people read it from are a presentation problem. The shape is Swift's own:
/// a value type, comparable, with a duration between two of them, so that when
/// there is a Foundation to sit under this the change is which type is being
/// spelled and not what the code around it does.
///
/// Nanoseconds in a `UInt64` run to the year 2554, which is longer than the
/// machine will.
public struct Time: Equatable, Comparable, Sendable {

    /// Nanoseconds since 1970-01-01T00:00:00.
    public var nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// The clock before anybody set it. Not a valid date and not meant to be
    /// one: it is what a timestamp says when the machine did not know the time.
    public static let unknown = Time(nanoseconds: 0)

    public var isKnown: Bool { nanoseconds != 0 }

    public static func < (a: Time, b: Time) -> Bool { a.nanoseconds < b.nanoseconds }

    public static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    public static let secondsPerDay       : UInt64 = 86_400

    public var seconds: UInt64 { nanoseconds / Self.nanosecondsPerSecond }
    
    /// The date this instant falls on.
    ///
    /// The arithmetic is the standard days-from-civil pair, which is integer
    /// only and has no table of month lengths and no special case for
    /// centuries. Both directions are here because a system that can only
    /// print a date and not accept one is a system whose clock cannot be set.
    var civil: Civil {

        let total  = Int(seconds)
        let days   = total / Int(Self.secondsPerDay)
        var rest   = total % Int(Self.secondsPerDay)

        let hour   = rest / 3600
        rest      -= hour * 3600
        let minute = rest / 60
        let second = rest - minute * 60

        // Days shifted so the era starts on the 1st of March, which is what
        // removes the leap day from the middle of the year and with it every
        // special case.
        let shifted    = days + 719_468
        let era        = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra   = shifted - era * 146_097
        let yearOfEra  = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let year       = yearOfEra + era * 400
        let dayOfYear  = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthShift = (5 * dayOfYear + 2) / 153
        let day        = dayOfYear - (153 * monthShift + 2) / 5 + 1
        let month      = monthShift < 10 ? monthShift + 3 : monthShift - 9

        return Civil(
            year  : month <= 2 ? year + 1 : year,
            month : month,
            day   : day,
            hour  : hour,
            minute: minute,
            second: second
        )
    }


    /// The instant a date names. `nil` when the date is not one.
    init?(_ civil: Civil) {

        guard civil.month >= 1, civil.month <= 12,
              civil.day >= 1, civil.day <= 31,
              civil.hour >= 0, civil.hour < 24,
              civil.minute >= 0, civil.minute < 60,
              civil.second >= 0, civil.second < 60,
              civil.year >= 1970, civil.year <= 2500
        else { return nil }

        let year       = civil.month <= 2 ? civil.year - 1 : civil.year
        // Years before 1970 are refused above, so the negative branch of this
        // rounding cannot be reached and is not tested. It is written the
        // standard way anyway: the day the epoch moves, it will be right.
        let era        = (year >= 0 ? year : year - 399) / 400
        let yearOfEra  = year - era * 400
        let monthShift = civil.month > 2 ? civil.month - 3 : civil.month + 9
        let dayOfYear  = (153 * monthShift + 2) / 5 + civil.day - 1
        let dayOfEra   = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days       = era * 146_097 + dayOfEra - 719_468

        guard days >= 0 else { return nil }

        // The day has to survive the round trip, which is what catches the 31st
        // of February without a table of month lengths to check it against.
        let seconds = UInt64(days) * Self.secondsPerDay
            + UInt64(civil.hour) * 3600
            + UInt64(civil.minute) * 60
            + UInt64(civil.second)

        let candidate = Time(nanoseconds: seconds * Self.nanosecondsPerSecond)

        guard candidate.civil.day == civil.day,
              candidate.civil.month == civil.month,
              candidate.civil.year == civil.year
        else { return nil }

        self = candidate
    }


    /// This instant plus a number of nanoseconds.
    static func + (time: Time, nanoseconds: UInt64) -> Time {
        Time(nanoseconds: time.nanoseconds &+ nanoseconds)
    }

    /// Nanoseconds from `earlier` to this one, and zero when it is not earlier.
    func since(_ earlier: Time) -> UInt64 {
        nanoseconds > earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
    }
}
