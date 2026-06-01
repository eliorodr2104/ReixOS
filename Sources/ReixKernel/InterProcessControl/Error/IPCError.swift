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
    case notFoundFreeEndpoint
    case outOfEndpoints
    
    
    var status: IPCStatus {
        return switch self {
            case .wouldBlock                           : .wouldBlock
            case .notEnoughRights                      : .notEnoughRights
            case .invalidCapability                    : .invalidCapability
            case .timeout                              : .timeout
            case .noReply                              : .noReply
            case .invalidMessage                       : .invalidMessage
            case .notFoundFreeEndpoint, .outOfEndpoints: .outOfEndpoints
        }
    }
}
