//
//  ReixTextOutputSeverity.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

/// Importance as the producer means it. The presentation backend decides the
/// colour and the placement it gets.
public enum ReixTextOutputSeverity: UInt8, Equatable {
    case trace   = 0
    case debug   = 1
    case info    = 2
    case notice  = 3
    case warning = 4
    case error   = 5
    case fatal   = 6
}
