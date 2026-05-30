//
//  IPCError.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public enum IPCError: Error {
    case invalidCapability
    case notEnoughRights
    case wouldBlock
    case timeout
    case noReply
    case invalidMessage
}
