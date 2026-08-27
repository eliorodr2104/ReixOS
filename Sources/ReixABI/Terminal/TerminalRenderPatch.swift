//
//  TerminalRenderPatch.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct TerminalRenderPatch: Equatable {
    public static let headerBytes = 24
    public static let maximumText = 256
    public let kind: TerminalPatchKind
    public let sequence: UInt32
    public let amount: UInt16
    public let previousRows: UInt16
    public let previousCursorRow: UInt16
    public let cursorRow: UInt16
    public let cursorColumn: UInt16
    public let count: Int
    public let text: InlineArray<256, UInt8>

    public init(kind: TerminalPatchKind, sequence: UInt32, amount: UInt16 = 0) {
        self.kind = kind
        self.sequence = sequence
        self.amount = amount
        self.previousRows = 0
        self.previousCursorRow = 0
        self.cursorRow = 0
        self.cursorColumn = 0
        self.count = 0
        self.text = InlineArray(repeating: 0)
    }

    public init(
        kind: TerminalPatchKind,
        sequence: UInt32,
        bytes: UnsafePointer<UInt8>,
        count: Int,
        amount: UInt16 = 0,
        previousRows: UInt16 = 0,
        previousCursorRow: UInt16 = 0,
        cursorRow: UInt16 = 0,
        cursorColumn: UInt16 = 0
    ) {
        var payload = InlineArray<256, UInt8>(repeating: 0)
        let accepted = count >= 0 && count <= Self.maximumText
        if accepted { for index in 0..<count { payload[index] = bytes[index] } }
        self.kind = kind
        self.sequence = sequence
        self.amount = amount
        self.previousRows = previousRows
        self.previousCursorRow = previousCursorRow
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.count = accepted ? count : 0
        self.text = payload
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        let carriesText = kind == .insert || kind == .replaceBuffer
        guard count >= 0, count <= Self.maximumText, capacity >= Self.headerBytes + count,
              carriesText == (count > 0), validMetadata()
        else { return 0 }
        write16(bytes, 0, ShellProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write32(bytes, 4, sequence)
        write16(bytes, 8, amount)
        write16(bytes, 10, UInt16(count))
        write16(bytes, 12, previousRows)
        write16(bytes, 14, previousCursorRow)
        write16(bytes, 16, cursorRow)
        write16(bytes, 18, cursorColumn)
        write32(bytes, 20, 0)
        for index in 0..<count { bytes[Self.headerBytes + index] = text[index] }
        return Self.headerBytes + count
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> TerminalRenderPatch? {
        guard length >= Self.headerBytes, read16(bytes, 0) == ShellProtocol.version,
              let kind = TerminalPatchKind(rawValue: read16(bytes, 2)), read32(bytes, 20) == 0
        else { return nil }
        let amount = read16(bytes, 8)
        let count = Int(read16(bytes, 10))
        let carriesText = kind == .insert || kind == .replaceBuffer
        guard count <= Self.maximumText, length == Self.headerBytes + count,
              carriesText == (count > 0)
        else { return nil }
        let patch: TerminalRenderPatch
        if carriesText {
            patch = TerminalRenderPatch(
                kind: kind,
                sequence: read32(bytes, 4),
                bytes: bytes + Self.headerBytes,
                count: count,
                amount: amount,
                previousRows: read16(bytes, 12),
                previousCursorRow: read16(bytes, 14),
                cursorRow: read16(bytes, 16),
                cursorColumn: read16(bytes, 18)
            )
        } else {
            patch = TerminalRenderPatch(kind: kind, sequence: read32(bytes, 4), amount: amount)
        }
        return patch.validMetadata() ? patch : nil
    }

    private func validMetadata() -> Bool {
        switch kind {
            case .insert:
                return amount == 0 && previousRows == 0 && previousCursorRow == 0 && cursorRow == 0 && cursorColumn == 0
            case .replaceBuffer:
                guard amount == 0, previousRows > 0, previousCursorRow < previousRows else { return false }
                var rows = 1
                var row = 0
                var column = 0
                var selectedWidth = cursorRow == 0 ? 0 : -1
                for index in 0..<count {
                    if text[index] == 0x0A {
                        if row == Int(cursorRow) { selectedWidth = column }
                        rows += 1
                        row += 1
                        column = 0
                    } else if text[index] & 0xC0 != 0x80 {
                        column += 1
                    }
                }
                if row == Int(cursorRow) { selectedWidth = column }
                return Int(cursorRow) < rows && selectedWidth >= 0 && Int(cursorColumn) <= selectedWidth
            case .eraseBackward, .moveLeft, .moveRight:
                return amount > 0 && count == 0 && previousRows == 0 && previousCursorRow == 0 && cursorRow == 0 && cursorColumn == 0
            case .newline, .bell:
                return amount == 0 && count == 0 && previousRows == 0 && previousCursorRow == 0 && cursorRow == 0 && cursorColumn == 0
        }
    }

    public static func == (lhs: TerminalRenderPatch, rhs: TerminalRenderPatch) -> Bool {
        guard lhs.kind == rhs.kind, lhs.sequence == rhs.sequence, lhs.amount == rhs.amount,
              lhs.previousRows == rhs.previousRows, lhs.previousCursorRow == rhs.previousCursorRow,
              lhs.cursorRow == rhs.cursorRow, lhs.cursorColumn == rhs.cursorColumn,
              lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs.text[index] != rhs.text[index] { return false }
        return true
    }
}
