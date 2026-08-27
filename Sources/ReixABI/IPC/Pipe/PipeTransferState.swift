//
//  PipeTransferState.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct PipeTransferState {
    public private(set) var ended = false
    private var owner: (identity: UInt32, token: UInt32)? = nil

    public init() {}

    public func acceptsAttachment(identity: UInt32) -> Bool {
        owner == nil || owner?.identity == identity
    }

    public mutating func attach(identity: UInt32, token: UInt32) -> Bool {
        guard token != 0, acceptsAttachment(identity: identity) else { return false }
        owner = (identity, token)
        ended = false
        return true
    }

    public mutating func detach() {
        owner = nil
        ended = false
    }

    public mutating func checked(
        _ frame: PipeFrame,
        identity: UInt32,
        token: UInt32,
        extent: UInt64,
        destinationCapacity: Int
    ) -> PipeStatus {
        guard owner?.identity == identity, owner?.token == token, frame.token == token else {
            return .notOwner
        }
        let status = frame.checked(
            extent: extent,
            destinationCapacity: destinationCapacity,
            ended: ended
        )
        if status == .ok, frame.ends { ended = true }
        return status
    }
}
