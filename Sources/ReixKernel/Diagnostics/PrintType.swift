//
//  PrintType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/05/2026.
//

public enum PrintType {
    case message
    case error
    case warning
    case boot
    
    var message: String {
        switch self {
            case .message: "[MESSAGE]"
            case .error  : "[ ERROR ]"
            case .warning: "[WARNING]"
            case .boot   : "[ BOOT  ]"
        }
    }
}
