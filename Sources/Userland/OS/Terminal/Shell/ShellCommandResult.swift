//
//  ShellCommandResult.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

public struct ShellCommandResult {
    public let outcome: ShellOutcome
    public let status : ShellCommandStatus
    public let records: ShellResult
    public let frame  : ShellFrame?

    public init(
        outcome: ShellOutcome,
        status : ShellCommandStatus = .ok,
        records: ShellResult = ShellResult(),
        frame  : ShellFrame? = nil
    ) {
        self.outcome = outcome
        self.status = status
        self.records = records
        self.frame = frame
    }
}
