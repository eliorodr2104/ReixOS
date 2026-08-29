//
//  ReixTextSurfaceProtocol.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

/// The semantic screen command contract. VT bytes are an implementation detail
/// of VTAdapter and never occur in this protocol.
public enum ReixTextSurfaceProtocol {
    public static let version: UInt16 = 1
    public static let recordBytes = 288
    public static let headerBytes = 32
    public static let maximumPayload = 256
}

public enum ReixTextSurfaceKind: UInt16, Equatable {
    case insert = 1
    case eraseBackward = 2
    case moveLeft = 3
    case moveRight = 4
    case newline = 5
    case replaceBuffer = 6
    case bell = 7
}

/// A fixed 288-byte TextSurface command. Unused payload and header tail are
/// zero, which turns stale shared-page contents into a decoding failure.
public struct ReixTextSurfaceCommand: Equatable {
    public let kind: ReixTextSurfaceKind
    public let sequence: UInt32
    public let amount: UInt16
    public let previousRows: UInt16
    public let previousCursorRow: UInt16
    public let cursorRow: UInt16
    public let cursorColumn: UInt16
    public let count: Int
    public let text: InlineArray<256, UInt8>

    public init?(
        kind: ReixTextSurfaceKind,
        sequence: UInt32,
        amount: UInt16 = 0,
        bytes: UnsafePointer<UInt8>? = nil,
        count: Int = 0,
        previousRows: UInt16 = 0,
        previousCursorRow: UInt16 = 0,
        cursorRow: UInt16 = 0,
        cursorColumn: UInt16 = 0
    ) {
        var text = InlineArray<256, UInt8>(repeating: 0)
        guard sequence != 0, count >= 0, count <= ReixTextSurfaceProtocol.maximumPayload else { return nil }
        if count > 0 {
            guard let bytes, Self.validText(bytes, count: count) else { return nil }
            for index in 0..<count { text[index] = bytes[index] }
        }
        self.kind = kind
        self.sequence = sequence
        self.amount = amount
        self.previousRows = previousRows
        self.previousCursorRow = previousCursorRow
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.count = count
        self.text = text
        guard validMetadata() else { return nil }
    }

    public init?(kind: ReixTextSurfaceKind, sequence: UInt32, amount: UInt16 = 0) {
        self.init(kind: kind, sequence: sequence, amount: amount, bytes: nil, count: 0)
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixTextSurfaceProtocol.recordBytes, validMetadata() else { return false }
        for index in 0..<ReixTextSurfaceProtocol.recordBytes { bytes[index] = 0 }
        write16(bytes, 0, ReixTextSurfaceProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write16(bytes, 4, 0)
        write16(bytes, 6, UInt16(count))
        write32(bytes, 8, sequence)
        write16(bytes, 12, amount)
        write16(bytes, 14, previousRows)
        write16(bytes, 16, previousCursorRow)
        write16(bytes, 18, cursorRow)
        write16(bytes, 20, cursorColumn)
        for index in 0..<count { bytes[ReixTextSurfaceProtocol.headerBytes + index] = text[index] }
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixTextSurfaceCommand? {
        guard length == ReixTextSurfaceProtocol.recordBytes,
              read16(bytes, 0) == ReixTextSurfaceProtocol.version,
              let kind = ReixTextSurfaceKind(rawValue: read16(bytes, 2)),
              read16(bytes, 4) == 0,
              read16(bytes, 22) == 0,
              read32(bytes, 24) == 0,
              read32(bytes, 28) == 0
        else { return nil }
        let count = Int(read16(bytes, 6))
        guard count <= ReixTextSurfaceProtocol.maximumPayload,
              zero(
                  bytes,
                  from: ReixTextSurfaceProtocol.headerBytes + count,
                  through: ReixTextSurfaceProtocol.recordBytes
              )
        else { return nil }
        return ReixTextSurfaceCommand(
            kind: kind,
            sequence: read32(bytes, 8),
            amount: read16(bytes, 12),
            bytes: count == 0 ? nil : bytes + ReixTextSurfaceProtocol.headerBytes,
            count: count,
            previousRows: read16(bytes, 14),
            previousCursorRow: read16(bytes, 16),
            cursorRow: read16(bytes, 18),
            cursorColumn: read16(bytes, 20)
        )
    }

    private func validMetadata() -> Bool {
        switch kind {
            case .insert:
                return count > 0 && amount == 0 && previousRows == 0
                    && previousCursorRow == 0 && cursorRow == 0 && cursorColumn == 0
            case .replaceBuffer:
                guard count > 0, amount == 0, previousRows > 0, previousCursorRow < previousRows else { return false }
                var rows = 1
                var row = 0
                var column = 0
                var selected = cursorRow == 0 ? 0 : -1
                for index in 0..<count {
                    if text[index] == 0x0A {
                        if row == Int(cursorRow) { selected = column }
                        rows += 1
                        row += 1
                        column = 0
                    } else if text[index] & 0xC0 != 0x80 {
                        column += 1
                    }
                }
                if row == Int(cursorRow) { selected = column }
                return Int(cursorRow) < rows && selected >= 0 && Int(cursorColumn) <= selected
            case .eraseBackward, .moveLeft, .moveRight:
                return amount > 0 && count == 0 && previousRows == 0
                    && previousCursorRow == 0 && cursorRow == 0 && cursorColumn == 0
            case .newline, .bell:
                return amount == 0 && count == 0 && previousRows == 0
                    && previousCursorRow == 0 && cursorRow == 0 && cursorColumn == 0
        }
    }

    private static func zero(_ bytes: UnsafePointer<UInt8>, from: Int, through: Int) -> Bool {
        for index in from..<through where bytes[index] != 0 { return false }
        return true
    }

    /// TextSurface carries printable Unicode text plus LF, never VT bytes.
    /// C0 controls, DEL and C1 controls are rejected before the adapter.
    private static func validText(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        ReixInputRecord.validText(bytes, count: count, allowsLF: true)
    }

    public static func == (lhs: ReixTextSurfaceCommand, rhs: ReixTextSurfaceCommand) -> Bool {
        guard lhs.kind == rhs.kind, lhs.sequence == rhs.sequence, lhs.amount == rhs.amount,
              lhs.previousRows == rhs.previousRows, lhs.previousCursorRow == rhs.previousCursorRow,
              lhs.cursorRow == rhs.cursorRow, lhs.cursorColumn == rhs.cursorColumn, lhs.count == rhs.count
        else { return false }
        for index in 0..<lhs.count where lhs.text[index] != rhs.text[index] { return false }
        return true
    }
}
