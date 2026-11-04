//
//  DeterministicClock.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

public struct DeterministicClock: Sendable {
    public private(set) var ticks: UInt64 = 0

    public init() {}

    public mutating func advance(by amount: UInt64 = 1) {
        ticks = ticks.addingReportingOverflow(amount).overflow ? UInt64.max : ticks + amount
    }
}
