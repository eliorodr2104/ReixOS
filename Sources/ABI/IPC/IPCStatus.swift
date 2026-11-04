//
//  IPCStatus.swift
//  ReixOS
//

/// How an IPC exchange went, as opposed to what was said in it.
///
/// `Error` so that it can be the failure side of a `call`: the transport not
/// having delivered anything is not a value in any protocol's status enum, and
/// the two must not share a channel. `ok` is zero in every one of those enums,
/// so a failure read as a reply reads as success.
public enum IPCStatus: UInt64, Error {
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
