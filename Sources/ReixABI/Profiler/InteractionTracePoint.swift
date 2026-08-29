//
//  InteractionTracePoint.swift
//  ReixOS
//
//  Created by Eliomar on 27/08/2026.
//


public enum InteractionTracePoint: UInt16, Equatable {
    case serialDelivered       = 1
    case inputDecoded          = 2
    case shellConsumed         = 3
    case editorCompleted       = 4
    case parserCompleted       = 5
    case presentationRequested = 6
    case consoleAcknowledged   = 7
}
