//
//  IPCStatus.swift
//  ReixOS
//
//  Shared IPC type (compiled into BOTH kernel and Reix module).
//

public enum IPCStatus: UInt64 {
    case ok = 0
    case wouldBlock
    case notEnoughRights
    case invalidCapability
    case timeout
    case noReply
    case invalidMessage
    case outOfEndpoints
}
