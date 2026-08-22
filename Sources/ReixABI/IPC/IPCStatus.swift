//
//  IPCStatus.swift
//  ReixOS
//

public enum IPCStatus: UInt64 {
    case ok              = 0
    case wouldBlock      = 1
    case notEnoughRights = 2
    case invalidCapability
    case timeout
    case noReply
    case invalidMessage
    case outOfEndpoints
    case peerDied
    case grantRejected

    public var isDelivered: Bool {
        switch self {
            case .ok, .grantRejected: true

            case .wouldBlock, .notEnoughRights, .invalidCapability,
                 .timeout, .noReply, .invalidMessage,
                 .outOfEndpoints, .peerDied: false
        }
    }
}
