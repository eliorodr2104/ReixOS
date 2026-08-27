//
//  TerminalInputEvent.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct TerminalInputEvent: Equatable {
    public static let headerBytes = 16
    public static let maximumText = 16
    public let kind: TerminalInputKind
    public let sequence: UInt32
    public let width: UInt16
    public let height: UInt16
    public let count: Int
    public let text: InlineArray<16, UInt8>

    public init(kind: TerminalInputKind, sequence: UInt32, width: UInt16 = 0, height: UInt16 = 0) {
        self.kind = kind
        self.sequence = sequence
        self.width = width
        self.height = height
        self.count = 0
        self.text = InlineArray(repeating: 0)
    }

    public init(sequence: UInt32, bytes: UnsafePointer<UInt8>, count: Int) {
        var payload = InlineArray<16, UInt8>(repeating: 0)
        let accepted = count > 0 && count <= Self.maximumText && Self.validUTF8(bytes, count: count)
        if accepted { for index in 0..<count { payload[index] = bytes[index] } }
        self.kind = .insert
        self.sequence = sequence
        self.width = 0
        self.height = 0
        self.count = accepted ? count : 0
        self.text = payload
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        guard count >= 0, count <= Self.maximumText, capacity >= Self.headerBytes + count,
              (kind == .insert) == (count > 0),
              kind != .insert || text.span.withUnsafeBufferPointer({ Self.validUTF8($0.baseAddress!, count: count) }),
              kind == .resize || (width == 0 && height == 0),
              kind != .resize || (width > 0 && height > 0 && count == 0)
        else { return 0 }
        write16(bytes, 0, ShellProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write32(bytes, 4, sequence)
        write16(bytes, 8, UInt16(count))
        write16(bytes, 10, width)
        write16(bytes, 12, height)
        write16(bytes, 14, 0)
        for index in 0..<count { bytes[Self.headerBytes + index] = text[index] }
        return Self.headerBytes + count
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> TerminalInputEvent? {
        guard length >= Self.headerBytes, read16(bytes, 0) == ShellProtocol.version,
              let kind = TerminalInputKind(rawValue: read16(bytes, 2)), read16(bytes, 14) == 0
        else { return nil }
        let count = Int(read16(bytes, 8))
        let width = read16(bytes, 10)
        let height = read16(bytes, 12)
        guard count <= Self.maximumText, length == Self.headerBytes + count,
              (kind == .insert) == (count > 0),
              kind != .insert || Self.validUTF8(bytes + Self.headerBytes, count: count),
              kind == .resize || (width == 0 && height == 0),
              kind != .resize || (width > 0 && height > 0 && count == 0)
        else { return nil }
        if kind == .insert {
            return TerminalInputEvent(sequence: read32(bytes, 4), bytes: bytes + Self.headerBytes, count: count)
        }
        return TerminalInputEvent(kind: kind, sequence: read32(bytes, 4), width: width, height: height)
    }

    public static func == (lhs: TerminalInputEvent, rhs: TerminalInputEvent) -> Bool {
        guard lhs.kind == rhs.kind, lhs.sequence == rhs.sequence, lhs.width == rhs.width,
              lhs.height == rhs.height, lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs.text[index] != rhs.text[index] { return false }
        return true
    }

    private static func validUTF8(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var index = 0
        while index < count {
            let first = bytes[index]
            let continuation: Int
            let secondRange: ClosedRange<UInt8>
            switch first {
                case 0x00...0x7F: continuation = 0; secondRange = 0x80...0xBF
                case 0xC2...0xDF: continuation = 1; secondRange = 0x80...0xBF
                case 0xE0: continuation = 2; secondRange = 0xA0...0xBF
                case 0xE1...0xEC, 0xEE...0xEF: continuation = 2; secondRange = 0x80...0xBF
                case 0xED: continuation = 2; secondRange = 0x80...0x9F
                case 0xF0: continuation = 3; secondRange = 0x90...0xBF
                case 0xF1...0xF3: continuation = 3; secondRange = 0x80...0xBF
                case 0xF4: continuation = 3; secondRange = 0x80...0x8F
                default: return false
            }
            guard continuation <= count - index - 1 else { return false }
            if continuation > 0 {
                guard secondRange.contains(bytes[index + 1]) else { return false }
                if continuation > 1 {
                    for offset in 2...continuation where bytes[index + offset] & 0xC0 != 0x80 { return false }
                }
            }
            index += continuation + 1
        }
        return true
    }
}
