//
//  ShellValue.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum ShellValue: Equatable {
    case void
    case boolean(Bool)
    case number(UInt64)
    case text(ShellText)
    case record(ShellObject)
    case sequence(Int)

    public var type: ShellValueType {
        switch self {
            case .void: .void
            case .boolean: .boolean
            case .number: .number
            case .text: .text
            case .record: .record
            case .sequence: .sequence
        }
    }
}
