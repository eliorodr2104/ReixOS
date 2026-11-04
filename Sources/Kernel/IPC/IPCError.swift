//
//  IPCError.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


import ReixABI

public enum IPCError: Error {
    case invalidCapability
    case notEnoughRights
    case wouldBlock
    case timeout
    case noReply
    case invalidMessage
    case notFoundFreeEndpoint
    case outOfEndpoints

    /// There is nobody left who can receive on that endpoint.
    ///
    /// Not `noReply`, which means a server dropped one request and is still
    /// there. This one says the other half of the rendezvous is gone, so
    /// waiting would be waiting for the rest of the boot.
    case peerDied
    
    
    var status: IPCStatus {
        switch self {
            case .wouldBlock                           : .wouldBlock
            case .notEnoughRights                      : .notEnoughRights
            case .invalidCapability                    : .invalidCapability
            case .timeout                              : .timeout
            case .noReply                              : .noReply
            case .invalidMessage                       : .invalidMessage
            case .notFoundFreeEndpoint, .outOfEndpoints: .outOfEndpoints
            case .peerDied                             : .peerDied
        }
    }
}
