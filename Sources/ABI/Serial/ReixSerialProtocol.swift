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

/// Forty-eight bytes without relying on `InlineArray`'s aggregate value
/// representation across the freestanding module boundary. Serial chunks are
/// copied through optionals and IPC-facing helpers; keeping six scalar words
/// makes those copies ordinary Swift values while preserving indexed access.
@frozen
public struct ReixSerialPayload: Equatable {
    private var word0: UInt64 = 0
    private var word1: UInt64 = 0
    private var word2: UInt64 = 0
    private var word3: UInt64 = 0
    private var word4: UInt64 = 0
    private var word5: UInt64 = 0

    public init() {}

    public init?(bytes: UnsafePointer<UInt8>, count: Int) {
        guard count >= 0, count <= ReixSerialProtocol.maximumPayload else { return nil }
        for index in 0..<count { self[index] = bytes[index] }
    }

    public subscript(index: Int) -> UInt8 {
        get {
            precondition(index >= 0 && index < ReixSerialProtocol.maximumPayload)
            let shift = UInt64((index & 7) * 8)
            return UInt8(truncatingIfNeeded: word(index >> 3) >> shift)
        }
        set {
            precondition(index >= 0 && index < ReixSerialProtocol.maximumPayload)
            let slot = index >> 3
            let shift = UInt64((index & 7) * 8)
            let mask = UInt64(0xFF) << shift
            setWord(slot, (word(slot) & ~mask) | UInt64(newValue) << shift)
        }
    }

    /// Materializes a temporary contiguous view for parsers that consume a
    /// byte span. The scalar words themselves are never exposed as storage.
    public func withUnsafeBufferPointer<Result>(
        _ body: (UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result {
        withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity: ReixSerialProtocol.maximumPayload
        ) { bytes in
            for index in 0..<bytes.count { bytes[index] = self[index] }
            return body(UnsafeBufferPointer(bytes))
        }
    }

    private func word(_ index: Int) -> UInt64 {
        switch index {
            case 0: word0
            case 1: word1
            case 2: word2
            case 3: word3
            case 4: word4
            default: word5
        }
    }

    private mutating func setWord(_ index: Int, _ value: UInt64) {
        switch index {
            case 0: word0 = value
            case 1: word1 = value
            case 2: word2 = value
            case 3: word3 = value
            case 4: word4 = value
            default: word5 = value
        }
    }
}

/// A fixed wire record. Its bytes are copied into scalar payload storage.
public struct ReixSerialChunk: Equatable {
    public let direction: ReixSerialDirection
    public let flags: ReixSerialFlags
    public let sequence: UInt32
    public let count: Int
    public let payload: ReixSerialPayload

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
        guard let bytes else { return nil }
        self.direction = direction
        self.flags = flags
        self.sequence = sequence
        self.count = count
        guard let payload = ReixSerialPayload(bytes: bytes, count: count) else { return nil }
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
        var scalarPayload = ReixSerialPayload()
        for index in 0..<count { scalarPayload[index] = payload[index] }
        self.payload = scalarPayload
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
