//
//  ReixSerialServerProtocol.swift
//  ReixOS
//

public enum ReixSerialServerOperation: UInt32, IPCLabel {
    case registerReader = 1
    case registerWriter = 2
    case read = 3
    case write = 4
    case status = 5
}

public enum ReixSerialStatus: UInt32, Equatable {
    case ok = 0
    case empty = 1
    case full = 2
    case pending = 3
    case malformed = 4
    case stale = 5
    case timedOut = 6
    case refused = 7
}

public enum ReixSerialRingRole: UInt16, Equatable {
    case reader = 1
    case writer = 2
}

public enum ReixSerialRingState: UInt32, Equatable {
    case proposed = 1
    case accepted = 2
}

public enum ReixSerialRingTransport {
    public static let pageBytes = 4096
    public static let headerBytes = 64
    public static let capacity = 63
    public static let magic: UInt32 = 0x5358_4952
    public static let featureTypedChunks: UInt32 = 1 << 0
    public static let supportedFeatures = featureTypedChunks
}

/// The fixed serial ring header, encoded explicitly as little-endian bytes.
public struct ReixSerialRingHeader: Equatable {
    public let role: ReixSerialRingRole
    public let features: UInt32
    public let token: UInt32
    public let epoch: UInt64
    public let producer: UInt32
    public let consumer: UInt32
    public let state: ReixSerialRingState

    public init?(
        role: ReixSerialRingRole,
        features: UInt32 = ReixSerialRingTransport.supportedFeatures,
        token: UInt32,
        epoch: UInt64,
        producer: UInt32 = 0,
        consumer: UInt32 = 0,
        state: ReixSerialRingState
    ) {
        guard features == ReixSerialRingTransport.supportedFeatures,
              token != 0,
              producer &- consumer <= UInt32(ReixSerialRingTransport.capacity),
              (state == .proposed && epoch == 0 && producer == 0 && consumer == 0)
                  || (state == .accepted && epoch != 0)
        else { return nil }
        self.role = role
        self.features = features
        self.token = token
        self.epoch = epoch
        self.producer = producer
        self.consumer = consumer
        self.state = state
    }

    public static func proposal(role: ReixSerialRingRole, token: UInt32) -> ReixSerialRingHeader? {
        ReixSerialRingHeader(role: role, token: token, epoch: 0, state: .proposed)
    }

    public func accepted(epoch: UInt64) -> ReixSerialRingHeader? {
        ReixSerialRingHeader(
            role: role,
            features: features,
            token: token,
            epoch: epoch,
            producer: producer,
            consumer: consumer,
            state: .accepted
        )
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixSerialRingTransport.headerBytes else { return false }
        for index in 0..<ReixSerialRingTransport.headerBytes { bytes[index] = 0 }
        serialWrite32(bytes, 0, ReixSerialRingTransport.magic)
        serialWrite16(bytes, 4, ReixSerialProtocol.version)
        serialWrite16(bytes, 6, role.rawValue)
        serialWrite16(bytes, 8, UInt16(ReixSerialProtocol.recordBytes))
        serialWrite16(bytes, 10, UInt16(ReixSerialRingTransport.capacity))
        serialWrite32(bytes, 12, features)
        serialWrite32(bytes, 16, token)
        serialWrite64(bytes, 20, epoch)
        serialWrite32(bytes, 28, producer)
        serialWrite32(bytes, 32, consumer)
        serialWrite32(bytes, 36, state.rawValue)
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixSerialRingHeader? {
        guard length == ReixSerialRingTransport.headerBytes,
              serialRead32(bytes, 0) == ReixSerialRingTransport.magic,
              serialRead16(bytes, 4) == ReixSerialProtocol.version,
              let role = ReixSerialRingRole(rawValue: serialRead16(bytes, 6)),
              let state = ReixSerialRingState(rawValue: serialRead32(bytes, 36)),
              serialZero(bytes, from: 40, through: ReixSerialRingTransport.headerBytes)
        else { return nil }
        return ReixSerialRingHeader(
            role: role,
            features: serialRead32(bytes, 12),
            token: serialRead32(bytes, 16),
            epoch: serialRead64(bytes, 20),
            producer: serialRead32(bytes, 28),
            consumer: serialRead32(bytes, 32),
            state: state
        )
    }
}
