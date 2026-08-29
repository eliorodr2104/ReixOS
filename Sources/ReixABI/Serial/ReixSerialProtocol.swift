//
//  ReixSerialProtocol.swift
//  ReixOS
//

/// The raw serial boundary is the only place bytes are not yet terminal data.
public enum ReixSerialProtocol {
    public static let version: UInt16 = 1
    public static let recordBytes = 64
    public static let headerBytes = 16
    public static let maximumPayload = 48
}

public enum ReixSerialDirection: UInt16, Equatable {
    case receive = 1
    case transmit = 2
}

public struct ReixSerialFlags: OptionSet, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let endOfBatch = Self(rawValue: 1 << 0)
    public static let known: Self = [.endOfBatch]
}

/// A fixed wire record. Its bytes are copied into an inline buffer on decode.
public struct ReixSerialChunk: Equatable {
    public let direction: ReixSerialDirection
    public let flags: ReixSerialFlags
    public let sequence: UInt32
    public let count: Int
    public let payload: InlineArray<48, UInt8>

    public init?(
        direction: ReixSerialDirection,
        flags: ReixSerialFlags = [],
        sequence: UInt32,
        bytes: UnsafePointer<UInt8>? = nil,
        count: Int = 0
    ) {
        guard sequence != 0,
              flags.rawValue & ~ReixSerialFlags.known.rawValue == 0,
              count > 0,
              count <= ReixSerialProtocol.maximumPayload
        else { return nil }
        var payload = InlineArray<48, UInt8>(repeating: 0)
        if count > 0 {
            guard let bytes else { return nil }
            for index in 0..<count { payload[index] = bytes[index] }
        }
        self.direction = direction
        self.flags = flags
        self.sequence = sequence
        self.count = count
        self.payload = payload
    }

    public init?(
        direction: ReixSerialDirection,
        flags: ReixSerialFlags = [],
        sequence: UInt32,
        payload: InlineArray<48, UInt8>,
        count: Int
    ) {
        guard sequence != 0,
              flags.rawValue & ~ReixSerialFlags.known.rawValue == 0,
              count > 0,
              count <= ReixSerialProtocol.maximumPayload
        else { return nil }
        self.direction = direction
        self.flags = flags
        self.sequence = sequence
        self.count = count
        self.payload = payload
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixSerialProtocol.recordBytes,
              count <= ReixSerialProtocol.maximumPayload,
              flags.rawValue & ~ReixSerialFlags.known.rawValue == 0
        else { return false }
        for index in 0..<ReixSerialProtocol.recordBytes { bytes[index] = 0 }
        serialWrite16(bytes, 0, ReixSerialProtocol.version)
        serialWrite16(bytes, 2, direction.rawValue)
        serialWrite16(bytes, 4, flags.rawValue)
        serialWrite16(bytes, 6, UInt16(count))
        serialWrite32(bytes, 8, sequence)
        for index in 0..<count { bytes[ReixSerialProtocol.headerBytes + index] = payload[index] }
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixSerialChunk? {
        guard length == ReixSerialProtocol.recordBytes,
              serialRead16(bytes, 0) == ReixSerialProtocol.version,
              let direction = ReixSerialDirection(rawValue: serialRead16(bytes, 2))
        else { return nil }
        let flags = ReixSerialFlags(rawValue: serialRead16(bytes, 4))
        let count = Int(serialRead16(bytes, 6))
        guard flags.rawValue & ~ReixSerialFlags.known.rawValue == 0,
              count <= ReixSerialProtocol.maximumPayload,
              serialRead16(bytes, 14) == 0,
              serialRead32(bytes, 12) == 0,
              serialZero(bytes, from: ReixSerialProtocol.headerBytes + count, through: ReixSerialProtocol.recordBytes)
        else { return nil }
        return ReixSerialChunk(
            direction: direction,
            flags: flags,
            sequence: serialRead32(bytes, 8),
            bytes: count == 0 ? nil : bytes + ReixSerialProtocol.headerBytes,
            count: count
        )
    }

    public static func == (lhs: ReixSerialChunk, rhs: ReixSerialChunk) -> Bool {
        guard lhs.direction == rhs.direction,
              lhs.flags == rhs.flags,
              lhs.sequence == rhs.sequence,
              lhs.count == rhs.count
        else { return false }
        for index in 0..<lhs.count where lhs.payload[index] != rhs.payload[index] { return false }
        return true
    }
}

public func serialRead16(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

public func serialRead32(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

public func serialRead64(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
    UInt64(serialRead32(bytes, offset)) | UInt64(serialRead32(bytes, offset + 4)) << 32
}

public func serialWrite16(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

public func serialWrite32(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt32) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

public func serialWrite64(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt64) {
    serialWrite32(bytes, offset, UInt32(truncatingIfNeeded: value))
    serialWrite32(bytes, offset + 4, UInt32(truncatingIfNeeded: value >> 32))
}

public func serialZero(_ bytes: UnsafePointer<UInt8>, from: Int, through: Int) -> Bool {
    for index in from..<through where bytes[index] != 0 { return false }
    return true
}
