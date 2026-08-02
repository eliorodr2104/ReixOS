//
//  PendingMessage.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//

import ReixABI


public struct PendingMessage {

    public let message     : Message   // 21 Byte -> (4 * 4) + (4 + 1)
    public let session     : Badge     // 4 Byte
    public let grant       : UInt32?   // 5 Byte
    public let rights      : CapRights // 1 Byte
    public let expectsReply: Bool      // 1 Byte


    public init(
        message     : Message,
        session     : Badge,
        grant       : UInt32?,
        rights      : CapRights,
        expectsReply: Bool
    ) {
        self.message      = message
        self.session      = session
        self.grant        = grant
        self.rights       = rights
        self.expectsReply = expectsReply
    }
}
