//
//  ReixTextSurfaceTransport.swift
//  ReixOS
//

/// Layout constants for one bounded TextSurface transaction region.
public enum ReixTextSurfaceTransport {
    public static let pageBytes = 4096
    public static let pages = 3
    public static let regionBytes = pageBytes * pages
    public static let headerBytes = 64
    public static let magic: UInt32 = 0x5358_4952 // "RIXS" little-endian
    public static let version: UInt16 = 3
    public static let featureTypedFrames: UInt32 = 1 << 0
    public static let featureGeometry: UInt32 = 1 << 1
    public static let featureSemanticStyles: UInt32 = 1 << 2
    public static let featureViewport: UInt32 = 1 << 3
    public static let featureOverlay: UInt32 = 1 << 4
    public static let featureIncrementalUpdates: UInt32 = 1 << 5
    public static let featureFullSnapshot: UInt32 = 1 << 6
    public static let featureAcknowledgements: UInt32 = 1 << 7
    public static let featureResynchronization: UInt32 = 1 << 8
    public static let featurePresentationModes: UInt32 = 1 << 9
    public static let supportedFeatures = featureTypedFrames | featureGeometry | featureSemanticStyles
        | featureViewport | featureOverlay | featureIncrementalUpdates | featureFullSnapshot
        | featureAcknowledgements | featureResynchronization
        | featurePresentationModes
    public static let requiredFeatures = supportedFeatures
    public static let capacity = (regionBytes - headerBytes) / ReixTextSurfaceProtocol.recordBytes
    public static let maximumFrameRecords = 2 + (
        ReixTextSurfaceFrameDescriptor.maximumTextBytes
            + ReixTextSurfaceFrameDescriptor.maximumOverlayBytes
            + Int(ReixTextSurfaceFrameDescriptor.maximumStyleSpans) * ReixTextSurfaceStyleSpan.wireBytes
            + Int(ReixTextSurfaceFrameDescriptor.maximumOverlayStyleSpans) * ReixTextSurfaceStyleSpan.wireBytes
            + ReixTextSurfaceFrameRecord.payloadBytes - 1
    ) / ReixTextSurfaceFrameRecord.payloadBytes
}

/// Sequence domains distinguish input-correlated work from asynchronous output.
public enum ReixInteractionSequence {
    public static let asynchronousBit: UInt32 = 0x8000_0000
    public static let maximumCorrelated = asynchronousBit - 1

    public static func nextCorrelated(after value: UInt32) -> UInt32 {
        value == 0 || value >= maximumCorrelated ? 1 : value + 1
    }

    public static func nextAsynchronous(after value: UInt32) -> UInt32 {
        value < asynchronousBit || value == UInt32.max ? asynchronousBit : value + 1
    }

    public static func isCorrelated(_ value: UInt32) -> Bool {
        value != 0 && value <= maximumCorrelated
    }
}

public enum ReixTextSurfaceRingState: UInt32, Equatable {
    case proposed = 1
    case accepted = 2
}

public enum ReixTextSurfaceAckStatus: UInt32, Equatable {
    case pending = 0
    case committed = 1
    case snapshotRequired = 2
    case hardwareFailure = 3
    case malformed = 4
    case stale = 5
}

public struct ReixTextSurfaceAcknowledgement: Equatable {
    public let status: ReixTextSurfaceAckStatus
    public let transaction: UInt32
    public let revision: UInt32
    public let baseRevision: UInt32
    public let token: UInt32
    public let epoch: UInt64

    public init?(
        status: ReixTextSurfaceAckStatus,
        transaction: UInt32,
        revision: UInt32,
        baseRevision: UInt32,
        token: UInt32,
        epoch: UInt64
    ) {
        guard status != .pending,
              transaction != 0,
              status != .committed || revision != 0,
              token != 0,
              epoch != 0
        else { return nil }
        self.status = status
        self.transaction = transaction
        self.revision = revision
        self.baseRevision = baseRevision
        self.token = token
        self.epoch = epoch
    }
}

/// The fixed 64-byte little-endian header of a TextSurface SPSC page.
public struct ReixTextSurfaceRingHeader: Equatable {
    public let recordBytes: UInt16
    public let capacity: UInt16
    public let features: UInt32
    public let epoch: UInt64
    public let token: UInt32
    public let producer: UInt32
    public let consumer: UInt32
    public let state: ReixTextSurfaceRingState

    public init?(
        recordBytes: UInt16,
        capacity: UInt16,
        features: UInt32,
        epoch: UInt64,
        token: UInt32,
        producer: UInt32 = 0,
        consumer: UInt32 = 0,
        state: ReixTextSurfaceRingState
    ) {
        guard token != 0,
              recordBytes == UInt16(ReixTextSurfaceProtocol.recordBytes),
              capacity == UInt16(ReixTextSurfaceTransport.capacity),
              ReixTextSurfaceTransport.validFeatures(features),
              state == .proposed ? epoch == 0 && producer == 0 && consumer == 0 : epoch != 0,
              producer &- consumer <= UInt32(capacity)
        else {
            return nil
        }
        self.recordBytes = recordBytes
        self.capacity = capacity
        self.features = features
        self.epoch = epoch
        self.token = token
        self.producer = producer
        self.consumer = consumer
        self.state = state
    }

    public static func proposal(token: UInt32) -> ReixTextSurfaceRingHeader? {
        ReixTextSurfaceRingHeader(
            recordBytes: UInt16(ReixTextSurfaceProtocol.recordBytes),
            capacity: UInt16(ReixTextSurfaceTransport.capacity),
            features: ReixTextSurfaceTransport.requiredFeatures,
            epoch: 0,
            token: token,
            state: .proposed
        )
    }

    public func accepted(epoch: UInt64) -> ReixTextSurfaceRingHeader? {
        ReixTextSurfaceRingHeader(
            recordBytes: recordBytes,
            capacity: capacity,
            features: features,
            epoch: epoch,
            token: token,
            producer: producer,
            consumer: consumer,
            state: .accepted
        )
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixTextSurfaceTransport.headerBytes else {
            return false
        }
        guard ReixTextSurfaceTransport.maximumFrameRecords <= ReixTextSurfaceTransport.capacity else {
            return false
        }
        for index in 0..<ReixTextSurfaceTransport.headerBytes {
            bytes[index] = 0
        }
        write32(bytes, 0, ReixTextSurfaceTransport.magic)
        write16(bytes, 4, ReixTextSurfaceTransport.version)
        write16(bytes, 6, 0)
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
    ) -> ReixTextSurfaceRingHeader? {
        guard length == ReixTextSurfaceTransport.headerBytes,
              read32(bytes, 0) == ReixTextSurfaceTransport.magic,
              read16(bytes, 4) == ReixTextSurfaceTransport.version,
              read16(bytes, 6) == 0,
              let state = ReixTextSurfaceRingState(rawValue: read32(bytes, 36)),
              let ackStatus = ReixTextSurfaceAckStatus(rawValue: read32(bytes, 40)),
              ackStatus == .pending
                  ? read32(bytes, 44) == 0 && read32(bytes, 48) == 0 && read32(bytes, 52) == 0
                  : read32(bytes, 44) != 0 && (ackStatus != .committed || read32(bytes, 48) != 0),
              read32(bytes, 56) == 0,
              read32(bytes, 60) == 0
        else {
            return nil
        }
        return ReixTextSurfaceRingHeader(
            recordBytes: read16(bytes, 8),
            capacity: read16(bytes, 10),
            features: read32(bytes, 12),
            epoch: read64(bytes, 16),
            token: read32(bytes, 24),
            producer: producer ?? read32(bytes, 28),
            consumer: consumer ?? read32(bytes, 32),
            state: state
        )
    }

    private static func zero(_ bytes: UnsafePointer<UInt8>, from: Int, through: Int) -> Bool {
        for index in from..<through where bytes[index] != 0 {
            return false
        }
        return true
    }
}

extension ReixTextSurfaceTransport {
    public static func validFeatures(_ features: UInt32) -> Bool {
        guard features & ~supportedFeatures == 0,
              features & requiredFeatures == requiredFeatures
        else { return false }
        let hasPatch = features & featureIncrementalUpdates != 0
        let hasSnapshot = features & featureFullSnapshot != 0
        let hasFrames = features & featureTypedFrames != 0
        let hasGeometry = features & featureGeometry != 0
        let hasAcknowledgements = features & featureAcknowledgements != 0
        let hasResync = features & featureResynchronization != 0
        return hasFrames && hasGeometry && hasPatch && hasSnapshot && hasAcknowledgements && hasResync
    }
}

/// Requests accepted by the TextSurface server endpoint.
public enum ReixTextSurfaceOperation: UInt32, IPCLabel {
    case register
    case status
    case present

    public func message(word0: UInt32 = 0, word1: UInt32? = nil) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = word0
        if let word1 {
            words[1] = word1
        }
        return Message(tag: MessageTag(self, length: word1 == nil ? 1 : 2), words: words)
    }
}

/// Status values returned by TextSurface requests.
public enum ReixTextSurfaceStatus: UInt32 {
    case ok = 0
    case unregistered = 1
    case refused = 2
    case malformed = 3
    case backpressure = 4
    case snapshotRequired = 5
    case hardwareFailure = 6
}

private func read64(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
    UInt64(read32(bytes, offset)) | UInt64(read32(bytes, offset + 4)) << 32
}

private func write64(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt64) {
    write32(bytes, offset, UInt32(truncatingIfNeeded: value))
    write32(bytes, offset + 4, UInt32(truncatingIfNeeded: value >> 32))
}
