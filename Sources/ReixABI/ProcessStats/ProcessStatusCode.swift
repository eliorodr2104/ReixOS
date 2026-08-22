//
//  ProcessStatusCode.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


/// The wire values of `ProcessStats.status`, mirroring the kernel's
/// `ProcessStatus`. That enum cannot carry a raw value itself, since two of
/// its cases hold an endpoint pointer, so this is the ABI copy.
@frozen
public enum ProcessStatusCode: UInt8 {

    case new              = 0
    case ready            = 1
    case running          = 2
    case waiting          = 3
    case blockedOnSend    = 4
    case blockedOnReceive = 5
    case blockedOnReply   = 6
    case terminated       = 7
}
