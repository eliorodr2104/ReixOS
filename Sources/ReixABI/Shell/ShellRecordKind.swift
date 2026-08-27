//
//  ShellRecordKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum ShellRecordKind: UInt16, Equatable {
    case status = 1
    case scalar = 2
    case text = 3
    case blobChunk = 4
}
