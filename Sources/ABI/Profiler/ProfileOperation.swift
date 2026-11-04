//
//  ProfileOperation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

public enum ProfileOperation: UInt64 {
    case disable          = 0
    case enable           = 1
    case reset            = 2
    case dumpConsole      = 3
    case setSampleDivider = 4
    case attachExport     = 5
    case pmuProbe         = 6
    case interactionMark  = 7
}
