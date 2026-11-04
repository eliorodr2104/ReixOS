//
//  ShellDiagnostic.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Something the analysis can say about a revision without running it.
///
/// Nothing here is fatal. A revision with diagnostics is still read whole, and
/// what is wrong is placed rather than thrown.
public enum ShellDiagnosticKind: UInt8, Equatable {
    case unknownReceiver
    case unknownCommand
    case unknownLabel
    case unknownMember
    case unbalanced
    case invalidByte
    case unterminatedText
}

public struct ShellDiagnostic: Equatable {
    public let kind : ShellDiagnosticKind
    public let start: UInt16
    public let count: UInt16

    public init(
        kind : ShellDiagnosticKind,
        start: UInt16,
        count: UInt16
    ) {
        self.kind = kind
        self.start = start
        self.count = count
    }

    public var span: Span { Span(start: Int(start), count: Int(count)) }

    /// One line, in the shell's own voice.
    public var message: StaticString {
        switch kind {
            case .unknownReceiver: return "no receiver answers to this name"
            case .unknownCommand: return "this receiver has no such command"
            case .unknownLabel: return "this command takes no such label"
            case .unknownMember: return "this value has no such member"
            case .unbalanced: return "nothing was opened for this to close"
            case .invalidByte: return "this begins nothing"
            case .unterminatedText: return "this text was never closed"
        }
    }
}
