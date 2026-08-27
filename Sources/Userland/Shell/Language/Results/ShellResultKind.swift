//
//  ShellResultKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public enum ShellResultKind: UInt16, Equatable {
    case presentation       = 1
    case fileSystemStatus   = 2
    case power              = 3
    case processList        = 4
    case process            = 5
    case processExit        = 6
    case processStart       = 7
    case truncated          = 8
    case unmount            = 9
    case blockGeometry      = 10
    case blockRead          = 11
    case blockStatus        = 12
    case fileSystemRoom     = 13
    case fileSystemPath     = 14
    case fileSystemEntry    = 15
    case fileSystemInfo     = 16
    case fileSystemTimes    = 17
    case fileSystemRead     = 18
    case fileSystemReadTail = 19
    case fileSystemWrite    = 20
    case fileSystemEmpty    = 21
}
