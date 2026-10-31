//
//  TimeTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI

/// Turning an instant into a date and back.
///
/// Calendar arithmetic is the kind of code that looks right and is wrong on
/// four days a century, so it is tested against the days nobody gets right by
/// accident: the end of February, the year 2000, the year 2100, and the ends of
/// months either side of a leap day.
@Suite("Time")
struct TimeTests {

    private func instant(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Time? {
        Time(Civil(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }


    @Test("the first instant of 1970 is zero seconds in")
    func theEpoch() {
        guard let epoch = instant(1970, 1, 1) else {
            Issue.record("the epoch is not a date")
            return
        }

        #expect(epoch.seconds == 0)

        // And zero nanoseconds is the clock nobody has set, which is why a
        // timestamp of zero is not a date but an admission.
        #expect(!Time.unknown.isKnown)
        #expect(epoch.civil == Civil(year: 1970, month: 1, day: 1))
    }


    @Test("a known instant lands where the rest of the world says it does")
    func knownInstants() {
        // 2001-09-09T01:46:40Z, the billionth second.
        let billion = Time(nanoseconds: 1_000_000_000 * Time.nanosecondsPerSecond)
        #expect(billion.civil == Civil(
            year: 2001, month: 9, day: 9, hour: 1, minute: 46, second: 40
        ))

        guard let midnight = instant(2026, 8, 23, 14, 30, 5) else {
            Issue.record("a plain date was refused")
            return
        }
        #expect(midnight.civil == Civil(
            year: 2026, month: 8, day: 23, hour: 14, minute: 30, second: 5
        ))
    }


    @Test("every date survives the trip out and back")
    func roundTrip() {
        let dates = [
            (1970, 1, 1), (1999, 12, 31), (2000, 1, 1),
            (2000, 2, 29),                       // a leap year, being divisible by 400
            (2024, 2, 29), (2024, 3, 1),
            (2026, 8, 23), (2100, 3, 1),         // 2100 is not a leap year
            (2400, 2, 29), (2500, 12, 31)
        ]

        for (year, month, day) in dates {
            guard let time = instant(year, month, day, 23, 59, 59) else {
                Issue.record("a real date was refused")
                continue
            }

            let back = time.civil
            #expect(back.year == year)
            #expect(back.month == month)
            #expect(back.day == day)
            #expect(back.hour == 23)
            #expect(back.second == 59)
        }
    }


    @Test("a day that is not a day is refused, and centuries are not all leap")
    func impossibleDates() {
        #expect(instant(2026, 2, 30) == nil)
        #expect(instant(2026, 2, 29) == nil)   // 2026 is not a leap year
        #expect(instant(2100, 2, 29) == nil)   // divisible by 100, not by 400
        #expect(instant(2026, 13, 1) == nil)
        #expect(instant(2026, 0, 1) == nil)
        #expect(instant(2026, 4, 31) == nil)   // April has thirty
        #expect(instant(2026, 1, 1, 24) == nil)
        #expect(instant(1969, 12, 31) == nil)  // before the epoch
    }


    @Test("2024 is a leap year and 2023 is not, counted in days")
    func leapYearLengths() {
        guard let start2024 = instant(2024, 1, 1),
              let start2025 = instant(2025, 1, 1),
              let start2023 = instant(2023, 1, 1)
        else {
            Issue.record("a new year is not a date")
            return
        }

        let day = Time.secondsPerDay
        #expect((start2025.seconds - start2024.seconds) / day == 366)
        #expect((start2024.seconds - start2023.seconds) / day == 365)
    }


    @Test("instants compare and subtract the way numbers do")
    func arithmetic() {
        guard let early = instant(2026, 1, 1), let late = instant(2026, 1, 2) else { return }

        #expect(early < late)
        #expect(late.since(early) == Time.secondsPerDay * Time.nanosecondsPerSecond)

        // Never negative, and never wrapping into a very large positive.
        #expect(early.since(late) == 0)

        #expect((early + Time.nanosecondsPerSecond).seconds == early.seconds + 1)
    }
}
