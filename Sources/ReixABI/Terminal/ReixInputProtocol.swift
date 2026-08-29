//
//  ReixInputProtocol.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

/// The InputServer-neutral keyboard contract carried from a terminal adapter to
/// an editor. It is deliberately a byte layout, not a Swift layout.
public enum ReixInputProtocol {
    public static let version: UInt16 = 1
    public static let recordBytes = 32
    public static let headerBytes = 16
    public static let maximumPayload = 16
}

public struct ReixInputModifiers: OptionSet, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift   = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let alt     = Self(rawValue: 1 << 2)
    public static let `super` = Self(rawValue: 1 << 3)
    public static let caps    = Self(rawValue: 1 << 4)

    public static let known: Self = [.shift, .control, .alt, .super, .caps]
}

public enum ReixInputKind: UInt16, Equatable {
    case insert = 1
    case left = 2
    case right = 3
    case up = 4
    case down = 5
    case home = 6
    case end = 7
    case backspace = 8
    case delete = 9
    case enter = 10
    case cancel = 11
    case eof = 12
    case historyPrevious = 13
    case historyNext = 14
    case resize = 15
    case ignored = 16
    case pasteBegin = 17
    case pasteEnd = 18
}

/// A fixed 32-byte record. Inline text is valid UTF-8 only for `.insert`.
public struct ReixInputRecord: Equatable {
    public let kind: ReixInputKind
    public let modifiers: ReixInputModifiers
    public let sequence: UInt32
    public let width: UInt16
    public let height: UInt16
    public let count: Int
    public let text: InlineArray<16, UInt8>

    public init?(
        kind: ReixInputKind,
        modifiers: ReixInputModifiers = [],
        sequence: UInt32,
        width: UInt16 = 0,
        height: UInt16 = 0,
        bytes: UnsafePointer<UInt8>? = nil,
        count: Int = 0
    ) {
        var text = InlineArray<16, UInt8>(repeating: 0)
        guard sequence != 0,
              modifiers.rawValue & ~ReixInputModifiers.known.rawValue == 0,
              count >= 0, count <= ReixInputProtocol.maximumPayload
        else { return nil }
        if count > 0 {
            guard let bytes, Self.validUTF8(bytes, count: count) else { return nil }
            for index in 0..<count { text[index] = bytes[index] }
        }
        guard Self.valid(kind: kind, count: count, width: width, height: height) else { return nil }
        self.kind = kind
        self.modifiers = modifiers
        self.sequence = sequence
        self.width = width
        self.height = height
        self.count = count
        self.text = text
    }

    public init?(kind: ReixInputKind, modifiers: ReixInputModifiers = [], sequence: UInt32, width: UInt16 = 0, height: UInt16 = 0) {
        self.init(kind: kind, modifiers: modifiers, sequence: sequence, width: width, height: height, bytes: nil, count: 0)
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixInputProtocol.recordBytes,
              modifiers.rawValue & ~ReixInputModifiers.known.rawValue == 0,
              Self.valid(kind: kind, count: count, width: width, height: height)
        else { return false }
        for index in 0..<ReixInputProtocol.recordBytes { bytes[index] = 0 }
        write16(bytes, 0, ReixInputProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write16(bytes, 4, modifiers.rawValue)
        write16(bytes, 6, UInt16(count))
        write32(bytes, 8, sequence)
        write16(bytes, 12, width)
        write16(bytes, 14, height)
        for index in 0..<count { bytes[ReixInputProtocol.headerBytes + index] = text[index] }
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixInputRecord? {
        guard length == ReixInputProtocol.recordBytes,
              read16(bytes, 0) == ReixInputProtocol.version,
              let kind = ReixInputKind(rawValue: read16(bytes, 2))
        else { return nil }
        let modifiers = ReixInputModifiers(rawValue: read16(bytes, 4))
        let count = Int(read16(bytes, 6))
        guard count <= ReixInputProtocol.maximumPayload,
              modifiers.rawValue & ~ReixInputModifiers.known.rawValue == 0,
              Self.valid(kind: kind, count: count, width: read16(bytes, 12), height: read16(bytes, 14)),
              Self.zero(bytes, from: ReixInputProtocol.headerBytes + count, through: ReixInputProtocol.recordBytes)
        else { return nil }
        return ReixInputRecord(kind: kind, modifiers: modifiers, sequence: read32(bytes, 8), width: read16(bytes, 12), height: read16(bytes, 14), bytes: count == 0 ? nil : bytes + ReixInputProtocol.headerBytes, count: count)
    }

    private static func valid(kind: ReixInputKind, count: Int, width: UInt16, height: UInt16) -> Bool {
        if kind == .insert { return count > 0 && width == 0 && height == 0 }
        if kind == .resize { return count == 0 && width > 0 && height > 0 }
        return count == 0 && width == 0 && height == 0
    }

    private static func zero(_ bytes: UnsafePointer<UInt8>, from: Int, through: Int) -> Bool {
        for index in from..<through where bytes[index] != 0 { return false }
        return true
    }

    static func validUTF8(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var index = 0
        while index < count {
            let first = bytes[index]
            let remaining: Int
            let second: ClosedRange<UInt8>
            switch first {
                case 0x00...0x7F: remaining = 0; second = 0x80...0xBF
                case 0xC2...0xDF: remaining = 1; second = 0x80...0xBF
                case 0xE0: remaining = 2; second = 0xA0...0xBF
                case 0xE1...0xEC, 0xEE...0xEF: remaining = 2; second = 0x80...0xBF
                case 0xED: remaining = 2; second = 0x80...0x9F
                case 0xF0: remaining = 3; second = 0x90...0xBF
                case 0xF1...0xF3: remaining = 3; second = 0x80...0xBF
                case 0xF4: remaining = 3; second = 0x80...0x8F
                default: return false
            }
            guard remaining <= count - index - 1 else { return false }
            if remaining > 0 {
                guard second.contains(bytes[index + 1]) else { return false }
                if remaining > 1 {
                    for offset in 2...remaining where bytes[index + offset] & 0xC0 != 0x80 { return false }
                }
            }
            index += remaining + 1
        }
        return true
    }

    public static func == (lhs: ReixInputRecord, rhs: ReixInputRecord) -> Bool {
        guard lhs.kind == rhs.kind, lhs.modifiers == rhs.modifiers, lhs.sequence == rhs.sequence,
              lhs.width == rhs.width, lhs.height == rhs.height, lhs.count == rhs.count
        else { return false }
        for index in 0..<lhs.count where lhs.text[index] != rhs.text[index] { return false }
        return true
    }
}
