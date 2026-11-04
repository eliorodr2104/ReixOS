//
//  ShellEnvelope.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct ShellEnvelope: Equatable {

    public let version      : UInt16
    public let schema       : ShellSchema
    public let sequence     : UInt32
    public let flags        : ShellFrameFlags
    public let recordCount  : UInt16
    public let payloadLength: UInt16

    public init?(
        version      : UInt16 = ShellProtocol.version,
        schema       : ShellSchema,
        sequence     : UInt32,
        flags        : ShellFrameFlags,
        recordCount  : UInt16,
        payloadLength: UInt16
    ) {
        guard version == ShellProtocol.version,
              flags.subtracting(.allowed).isEmpty,
              recordCount <= ShellProtocol.maximumRecords,
              Int(payloadLength) <= ShellProtocol.maximumPayload
        else { return nil }

        self.version       = version
        self.schema        = schema
        self.sequence      = sequence
        self.flags         = flags
        self.recordCount   = recordCount
        self.payloadLength = payloadLength
    }
}
