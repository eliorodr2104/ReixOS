//
//  ShellResultField.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public enum ShellResultField: UInt16, Equatable {
    case none            = 0
    case text            = 1
    case status          = 2
    case powerState      = 3
    case pid             = 4
    case processStatus   = 5
    case exitCode        = 6
    case programName     = 7
    case sectorCount     = 8
    case sectorSize      = 9
    case maximumRun      = 10
    case blockStatus     = 11
    case freeBlocks      = 12
    case fileSystemFlags = 13
    case fileSystemKind  = 14
    case entryName       = 15
    case byteCount       = 16
    case blockCount      = 17
    case createdAt       = 18
    case modifiedAt      = 19
    case sequence        = 20
    case sector          = 21
    case data            = 22
}
