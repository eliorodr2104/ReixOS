//
//  ReixTerminalTransport.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

/// Layout constants for the two-page terminal transport. The kernel grants and
/// maps pages; it does not interpret this client/server protocol.
public enum ReixTerminalTransport {
    public static let pageBytes = 4096
    public static let pages = 2
    public static let regionBytes = pageBytes * pages
    public static let headerBytes = 64
    public static let magic: UInt32 = 0x5458_4952 // "RIXT" little-endian
    public static let version: UInt16 = 1
    /// Both sides currently implement only fixed-size typed records.
    public static let featureTypedRecords: UInt32 = 1 << 0
    public static let supportedFeatures: UInt32 = featureTypedRecords
    public static let requiredFeatures: UInt32 = featureTypedRecords
    public static let inputCapacity = 126
    public static let surfaceCapacity = 14

    /// Input correlations use the low half; asynchronous output uses the high
    /// half so it cannot be mistaken for a key-to-screen interaction.
    public static let asynchronousSequenceBit: UInt32 = 0x8000_0000
    public static let maximumCorrelatedSequence: UInt32 = asynchronousSequenceBit - 1

    public static func nextCorrelatedSequence(after value: UInt32) -> UInt32 {
        value == 0 || value >= maximumCorrelatedSequence ? 1 : value + 1
    }

    public static func nextAsynchronousSequence(after value: UInt32) -> UInt32 {
        value < asynchronousSequenceBit || value == UInt32.max ? asynchronousSequenceBit : value + 1
    }

    public static func isCorrelatedSequence(_ value: UInt32) -> Bool {
        value != 0 && value <= maximumCorrelatedSequence
    }
}

public enum ReixTerminalRingRole: UInt16, Equatable {
    case input = 1
    case surface = 2
}

public enum ReixTerminalRingState: UInt32, Equatable {
    case proposed = 1
    case accepted = 2
}

/// The fixed 64-byte little-endian header of one SPSC page.
public struct ReixTerminalRingHeader: Equatable {
    public let role: ReixTerminalRingRole
    public let recordBytes: UInt16
    public let capacity: UInt16
    public let features: UInt32
    public let epoch: UInt64
    public let token: UInt32
    public let producer: UInt32
    public let consumer: UInt32
    public let state: ReixTerminalRingState

    public init?(
        role: ReixTerminalRingRole,
        recordBytes: UInt16,
        capacity: UInt16,
        features: UInt32,
        epoch: UInt64,
        token: UInt32,
        producer: UInt32 = 0,
        consumer: UInt32 = 0,
        state: ReixTerminalRingState
    ) {
        guard token != 0,
              features == ReixTerminalTransport.supportedFeatures,
              Self.matches(role: role, recordBytes: recordBytes, capacity: capacity),
              state == .proposed ? epoch == 0 && producer == 0 && consumer == 0 : epoch != 0,
              producer &- consumer <= UInt32(capacity)
        else { return nil }
        self.role = role
        self.recordBytes = recordBytes
        self.capacity = capacity
        self.features = features
        self.epoch = epoch
        self.token = token
        self.producer = producer
        self.consumer = consumer
        self.state = state
    }

    public static func proposal(role: ReixTerminalRingRole, token: UInt32) -> ReixTerminalRingHeader? {
        ReixTerminalRingHeader(role: role, recordBytes: expectedRecordBytes(role), capacity: expectedCapacity(role), features: ReixTerminalTransport.requiredFeatures, epoch: 0, token: token, state: .proposed)
    }

    public func accepted(epoch: UInt64) -> ReixTerminalRingHeader? {
        ReixTerminalRingHeader(role: role, recordBytes: recordBytes, capacity: capacity, features: features, epoch: epoch, token: token, producer: producer, consumer: consumer, state: .accepted)
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixTerminalTransport.headerBytes else { return false }
        for index in 0..<ReixTerminalTransport.headerBytes { bytes[index] = 0 }
        write32(bytes, 0, ReixTerminalTransport.magic)
        write16(bytes, 4, ReixTerminalTransport.version)
        write16(bytes, 6, role.rawValue)
        write16(bytes, 8, recordBytes)
        write16(bytes, 10, self.capacity)
        write32(bytes, 12, features)
        write64(bytes, 16, epoch)
        write32(bytes, 24, token)
        write32(bytes, 28, producer)
        write32(bytes, 32, consumer)
        write32(bytes, 36, state.rawValue)
        return true
    }

    public static func decode(
        _ bytes: UnsafePointer<UInt8>,
        length: Int,
        producer: UInt32? = nil,
        consumer: UInt32? = nil
    ) -> ReixTerminalRingHeader? {
        guard length == ReixTerminalTransport.headerBytes,
              read32(bytes, 0) == ReixTerminalTransport.magic,
              read16(bytes, 4) == ReixTerminalTransport.version,
              let role = ReixTerminalRingRole(rawValue: read16(bytes, 6)),
              let state = ReixTerminalRingState(rawValue: read32(bytes, 36)),
              zero(bytes, from: 40, through: ReixTerminalTransport.headerBytes)
        else { return nil }
        return ReixTerminalRingHeader(role: role, recordBytes: read16(bytes, 8), capacity: read16(bytes, 10), features: read32(bytes, 12), epoch: read64(bytes, 16), token: read32(bytes, 24), producer: producer ?? read32(bytes, 28), consumer: consumer ?? read32(bytes, 32), state: state)
    }

    public static func expectedRecordBytes(_ role: ReixTerminalRingRole) -> UInt16 {
        role == .input ? UInt16(ReixInputProtocol.recordBytes) : UInt16(ReixTextSurfaceProtocol.recordBytes)
    }

    public static func expectedCapacity(_ role: ReixTerminalRingRole) -> UInt16 {
        role == .input ? UInt16(ReixTerminalTransport.inputCapacity) : UInt16(ReixTerminalTransport.surfaceCapacity)
    }

    private static func matches(role: ReixTerminalRingRole, recordBytes: UInt16, capacity: UInt16) -> Bool {
        recordBytes == expectedRecordBytes(role) && capacity == expectedCapacity(role) && ReixTerminalTransport.headerBytes + Int(recordBytes) * Int(capacity) <= ReixTerminalTransport.pageBytes
    }

    private static func zero(_ bytes: UnsafePointer<UInt8>, from: Int, through: Int) -> Bool {
        for index in from..<through where bytes[index] != 0 { return false }
        return true
    }
}

private func read64(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
    UInt64(read32(bytes, offset)) | UInt64(read32(bytes, offset + 4)) << 32
}

private func write64(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt64) {
    write32(bytes, offset, UInt32(truncatingIfNeeded: value))
    write32(bytes, offset + 4, UInt32(truncatingIfNeeded: value >> 32))
}
