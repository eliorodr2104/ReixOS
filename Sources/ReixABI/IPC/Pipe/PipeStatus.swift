//
//  PipeStatus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum PipeStatus: UInt32, Equatable {
    case ok
    case invalidFrame
    case noAttachment
    case outOfBounds
    case destinationTooSmall
    case acknowledgementMismatch
    case ended
    case transportFailed
    case sourceFailed
    case notOwner
}
