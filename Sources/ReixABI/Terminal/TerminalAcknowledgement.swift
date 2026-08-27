//
//  TerminalAcknowledgement.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct TerminalAcknowledgement: Equatable {
    public let sequence: UInt32
    public let count: Int
    public let status: TerminalEventStatus

    public init(sequence: UInt32, count: Int, status: TerminalEventStatus) {
        self.sequence = sequence
        self.count = count
        self.status = status
    }

    public func accepts(_ event: TerminalEvent) -> Bool {
        status == .ok && event.status == .ok && sequence == event.sequence && count == event.count
    }
}
