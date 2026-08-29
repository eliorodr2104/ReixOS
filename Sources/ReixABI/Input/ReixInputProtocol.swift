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

public enum ReixInputPhase: UInt16, Equatable {
    case press = 0
    case release = 1
    case repeatKey = 2
}

public enum ReixInputKey: UInt16, Equatable {
    case none = 0
    case left = 1
    case right = 2
    case up = 3
    case down = 4
    case home = 5
    case end = 6
    case backspace = 7
    case delete = 8
    case enter = 9
    case cancel = 10
    case eof = 11
    case historyPrevious = 12
    case historyNext = 13
    case tab = 14
    case escape = 15
    case pageUp = 16
    case pageDown = 17
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
    case textChunk = 19
    case key = 20
    case pasteChunk = 21
    case compositionBegin = 22
    case compositionUpdate = 23
    case compositionCommit = 24
    case compositionCancel = 25
    case focusGained = 26
    case focusLost = 27
    case stateReset = 28
}

/// A fixed 32-byte record with bounded UTF-8 payloads for text-bearing kinds.
public struct ReixInputRecord: Equatable {
    public let kind: ReixInputKind
    public let modifiers: ReixInputModifiers
    public let sequence: UInt32
    public let width: UInt16
    public let height: UInt16
    public let logicalKey: ReixInputKey
    public let physicalKey: UInt16
    public let phase: ReixInputPhase
    public let repeatCount: UInt8
    public let count: Int
    public let text: InlineArray<16, UInt8>

    public init?(
        kind: ReixInputKind,
        modifiers: ReixInputModifiers = [],
        sequence: UInt32,
        width: UInt16 = 0,
        height: UInt16 = 0,
        logicalKey: ReixInputKey = .none,
        physicalKey: UInt16 = 0,
        phase: ReixInputPhase = .press,
        repeatCount: UInt8 = 0,
        bytes: UnsafePointer<UInt8>? = nil,
        count: Int = 0
    ) {
        var text = InlineArray<16, UInt8>(repeating: 0)
        guard sequence != 0,
              modifiers.rawValue & ~ReixInputModifiers.known.rawValue == 0,
              count >= 0, count <= ReixInputProtocol.maximumPayload,
              repeatCount <= 63
        else { return nil }
        if count > 0 {
            guard let bytes, Self.validUTF8(bytes, count: count) else { return nil }
            guard Self.validText(
                bytes,
                count: count,
                allowsLF: kind == .pasteChunk
            ) else { return nil }
            for index in 0..<count { text[index] = bytes[index] }
        }
        guard Self.valid(
            kind: kind,
            count: count,
            width: width,
            height: height,
            logicalKey: logicalKey,
            physicalKey: physicalKey,
            phase: phase,
            repeatCount: repeatCount
        ) else { return nil }
        self.kind = kind
        self.modifiers = modifiers
        self.sequence = sequence
        self.width = width
        self.height = height
        self.logicalKey = logicalKey
        self.physicalKey = physicalKey
        self.phase = phase
        self.repeatCount = repeatCount
        self.count = count
        self.text = text
    }

    public init?(
        kind: ReixInputKind,
        modifiers: ReixInputModifiers = [],
        sequence: UInt32,
        width: UInt16 = 0,
        height: UInt16 = 0
    ) {
        self.init(
            kind: kind,
            modifiers: modifiers,
            sequence: sequence,
            width: width,
            height: height,
            bytes: nil,
            count: 0
        )
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixInputProtocol.recordBytes,
              modifiers.rawValue & ~ReixInputModifiers.known.rawValue == 0,
              Self.valid(
                  kind: kind,
                  count: count,
                  width: width,
                  height: height,
                  logicalKey: logicalKey,
                  physicalKey: physicalKey,
                  phase: phase,
                  repeatCount: repeatCount
              )
        else { return false }
        for index in 0..<ReixInputProtocol.recordBytes { bytes[index] = 0 }
        write16(bytes, 0, ReixInputProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write16(bytes, 4, modifiers.rawValue | phase.rawValue << 8 | UInt16(repeatCount) << 10)
        write16(bytes, 6, UInt16(count))
        write32(bytes, 8, sequence)
        write16(bytes, 12, kind == .key ? logicalKey.rawValue : width)
        write16(bytes, 14, kind == .key ? physicalKey : height)
        for index in 0..<count { bytes[ReixInputProtocol.headerBytes + index] = text[index] }
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixInputRecord? {
        guard length == ReixInputProtocol.recordBytes,
              read16(bytes, 0) == ReixInputProtocol.version,
              let kind = ReixInputKind(rawValue: read16(bytes, 2))
        else { return nil }
        let flags = read16(bytes, 4)
        let modifiers = ReixInputModifiers(rawValue: flags & 0x001F)
        let count = Int(read16(bytes, 6))
        guard count <= ReixInputProtocol.maximumPayload,
              flags & 0x00E0 == 0,
              let phase = ReixInputPhase(rawValue: (flags >> 8) & 0x3),
              modifiers.rawValue & ~ReixInputModifiers.known.rawValue == 0,
              let logicalKey = kind == .key ? ReixInputKey(rawValue: read16(bytes, 12)) : ReixInputKey.none,
              Self.valid(
                  kind: kind,
                  count: count,
                  width: kind == .key ? 0 : read16(bytes, 12),
                  height: kind == .key ? 0 : read16(bytes, 14),
                  logicalKey: logicalKey,
                  physicalKey: kind == .key ? read16(bytes, 14) : 0,
                  phase: phase,
                  repeatCount: UInt8(flags >> 10)
              ),
              Self.zero(bytes, from: ReixInputProtocol.headerBytes + count, through: ReixInputProtocol.recordBytes)
        else { return nil }
        return ReixInputRecord(
            kind: kind,
            modifiers: modifiers,
            sequence: read32(bytes, 8),
            width: kind == .key ? 0 : read16(bytes, 12),
            height: kind == .key ? 0 : read16(bytes, 14),
            logicalKey: logicalKey,
            physicalKey: kind == .key ? read16(bytes, 14) : 0,
            phase: phase,
            repeatCount: UInt8(flags >> 10),
            bytes: count == 0 ? nil : bytes + ReixInputProtocol.headerBytes,
            count: count
        )
    }

    private static func valid(
        kind: ReixInputKind,
        count: Int,
        width: UInt16,
        height: UInt16,
        logicalKey: ReixInputKey,
        physicalKey: UInt16,
        phase: ReixInputPhase,
        repeatCount: UInt8
    ) -> Bool {
        if kind == .key {
            return count == 0
                && width == 0
                && height == 0
                && logicalKey != .none
                && physicalKey != 0
                && (phase != .repeatKey || repeatCount > 0)
                && (phase == .repeatKey || repeatCount == 0)
        }
        guard logicalKey == .none, physicalKey == 0, phase == .press, repeatCount == 0 else { return false }
        if kind == .insert || kind == .textChunk || kind == .pasteChunk
            || kind == .compositionUpdate || kind == .compositionCommit
        {
            return count > 0 && width == 0 && height == 0
        }
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

    static func validText(
          _ bytes: UnsafePointer<UInt8>,
          count: Int,
          allowsLF: Bool
    ) -> Bool {
        guard validUTF8(bytes, count: count) else { return false }
        var index = 0
        while index < count {
            let byte = bytes[index]
            if byte < 0x20,
               (!allowsLF || byte != 0x0A) {
                return false
            }
            if byte == 0x7F { return false }
            if byte == 0xC2,
               index + 1 < count,
               (0x80...0x9F).contains(bytes[index + 1]) {
                return false
            }
            if byte < 0x80 { index += 1 }
            else if byte < 0xE0 { index += 2 }
            else if byte < 0xF0 { index += 3 }
            else { index += 4 }
        }
        return true
    }

    public static func == (lhs: ReixInputRecord, rhs: ReixInputRecord) -> Bool {
        guard lhs.kind == rhs.kind, lhs.modifiers == rhs.modifiers, lhs.sequence == rhs.sequence,
              lhs.width == rhs.width, lhs.height == rhs.height, lhs.logicalKey == rhs.logicalKey,
              lhs.physicalKey == rhs.physicalKey, lhs.phase == rhs.phase,
              lhs.repeatCount == rhs.repeatCount, lhs.count == rhs.count
        else { return false }
        for index in 0..<lhs.count where lhs.text[index] != rhs.text[index] { return false }
        return true
    }
}
