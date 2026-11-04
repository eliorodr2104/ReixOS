//
//  LaunchDeadlineTests.swift
//  ReixOS
//

import Testing
@testable import ProcessServerCore

@Suite("Launch deadlines")
struct LaunchDeadlineTests {
    @Test func deadlineBoundaries() throws {
        let deadline = try #require(LaunchDeadline(from: 5_000, milliseconds: 10, frequency: 1_000_000))
        #expect(!deadline.reached(at: 14_999))
        #expect(deadline.reached(at: 15_000))
        #expect(LaunchDeadline(from: 5_000, milliseconds: 0, frequency: 1_000_000)?.reached(at: 5_000) == true)
    }

    @Test func deadlineAcrossCounterWrap() throws {
        let deadline = try #require(LaunchDeadline(from: UInt64.max - 500, milliseconds: 1, frequency: 1_000_000))
        #expect(deadline.counter == 499)
        #expect(!deadline.reached(at: UInt64.max))
        #expect(!deadline.reached(at: 498))
        #expect(deadline.reached(at: 499))
    }

    @Test func deadlineRefusesUnusableClocks() {
        #expect(LaunchDeadline(from: 0, milliseconds: 1, frequency: 0) == nil)
        #expect(LaunchDeadline(from: 0, milliseconds: 1, frequency: 999) == nil)
        #expect(LaunchDeadline(from: 0, milliseconds: 7, frequency: 1000)?.counter == 7)
    }

    @Test func deadlineRefusesOverflow() {
        #expect(LaunchDeadline(from: 0, milliseconds: UInt64(Int64.max), frequency: 1000) != nil)
        #expect(LaunchDeadline(from: 0, milliseconds: UInt64(Int64.max) + 1, frequency: 1000) == nil)
        #expect(LaunchDeadline(from: 0, milliseconds: 2_000_000, frequency: UInt64.max) == nil)
        #expect(LaunchDeadline(from: 0, milliseconds: UInt64(1) << 63, frequency: 2000) == nil)
    }
}
