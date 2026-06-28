//
//  PrintType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/05/2026.
//

/// Severity tag prepended to every kernel log line.
///
/// The width of the formatted prefix is fixed at 9 characters
/// (brackets included) so consecutive lines align visually in any
/// serial-attached terminal. Levels are ordered from least to most
/// severe; the panic level is reserved to `Arch.CPU.panic` and never
/// produced by ordinary kprint calls.
public enum PrintType {
    case debug
    case info
    case message
    case warning
    case error
    case boot
    case panic

    var message: String {
        switch self {
            case .debug  : "[ DEBUG ]"
            case .info   : "[ INFO  ]"
            case .message: "[MESSAGE]"
            case .warning: "[WARNING]"
            case .error  : "[ ERROR ]"
            case .boot   : "[ BOOT  ]"
            case .panic  : "[ PANIC ]"
        }
    }
}
