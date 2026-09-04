//
//  ReixTextLayout.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

/// The bounded Unicode profile shared by the editor and every text surface.
public enum ReixTextLayout {
    public static let unicodeMajor: UInt16 = 16
    public static let unicodeMinor: UInt16 = 0

    public struct Position: Equatable {
        public let row: UInt16
        public let column: UInt16

        public init(row: UInt16, column: UInt16) {
            self.row = row
            self.column = column
        }
    }

    private struct Scalar {
        let value: UInt32
        let length: Int
    }

    private enum EmojiJoinState { case none, pictograph, joined }
    private enum IndicJoinState { case none, consonant, linked }

    public static func validUTF8(
        count: Int,
        byte: (Int) -> UInt8?
    ) -> Bool {
        guard count >= 0 else { return false }
        var offset = 0
        while offset < count {
            guard let scalar = decode(at: offset, count: count, byte: byte) else { return false }
            if scalar.value != 0x0A && isControl(scalar.value) { return false }
            offset += scalar.length
        }
        return true
    }

    public static func nextGraphemeBoundary(
        after offset: Int,
        count: Int,
        byte: (Int) -> UInt8?
    ) -> Int? {
        guard offset >= 0, offset < count,
              let first = decode(at: offset, count: count, byte: byte)
        else { return nil }
        var cursor = offset + first.length
        var previous = ReixUnicode16Tables.graphemeBreak(first.value)
        var regionalCount = previous == .regionalIndicator ? 1 : 0
        var emojiState: EmojiJoinState = isExtendedPictograph(first.value) ? .pictograph : .none
        var indicState: IndicJoinState = ReixUnicode16Tables.indicConjunct(first.value) == .consonant
            ? .consonant
            : .none
        while cursor < count {
            guard let next = decode(at: cursor, count: count, byte: byte) else { return nil }
            let nextBreak = ReixUnicode16Tables.graphemeBreak(next.value)
            let nextIndic = ReixUnicode16Tables.indicConjunct(next.value)
            let joins = joins(
                previous: previous,
                next: nextBreak,
                nextValue: next.value,
                regionalCount: regionalCount,
                emojiState: emojiState,
                indicState: indicState,
                nextIndic: nextIndic
            )
            if !joins { break }
            regionalCount = nextBreak == .regionalIndicator ? regionalCount + 1 : 0
            emojiState = advanceEmoji(emojiState, value: next.value, property: nextBreak)
            indicState = advanceIndic(indicState, property: nextIndic)
            previous = nextBreak
            cursor += next.length
        }
        return cursor
    }

    public static func previousGraphemeBoundary(
        before offset: Int,
        count: Int,
        byte: (Int) -> UInt8?
    ) -> Int? {
        guard offset > 0, offset <= count else { return nil }
        let candidate = offset - 1
        if let last = byte(candidate), last < 0x80 {
            if candidate == 0 { return 0 }
            if let previous = byte(candidate - 1), previous < 0x80 {
                if last == 0x0A && previous == 0x0D { return candidate - 1 }
                return candidate
            }
        }
        var cursor = 0
        var previous = 0
        while cursor < offset {
            previous = cursor
            guard let next = nextGraphemeBoundary(after: cursor, count: count, byte: byte),
                  next <= offset
            else { return nil }
            cursor = next
        }
        return cursor == offset ? previous : nil
    }

    public static func isGraphemeBoundary(
        _ offset: Int,
        count: Int,
        byte: (Int) -> UInt8?
    ) -> Bool {
        guard offset >= 0, offset <= count else { return false }
        if offset == 0 || offset == count { return true }
        var cursor = 0
        while cursor < offset {
            guard let next = nextGraphemeBoundary(after: cursor, count: count, byte: byte) else {
                return false
            }
            cursor = next
        }
        return cursor == offset
    }

    public static func cellWidth(
        from offset: Int,
        to end: Int,
        count: Int,
        byte: (Int) -> UInt8?
    ) -> UInt16? {
        guard offset >= 0, end > offset, end <= count else { return nil }
        var cursor = offset
        var width: UInt16 = 0
        var hasVisibleScalar = false
        var hasEmojiScalar = false
        var regionalScalars = 0
        while cursor < end {
            guard let scalar = decode(at: cursor, count: count, byte: byte) else { return nil }
            if scalar.value == 0x0A { return 0 }
            if ReixUnicode16Tables.isEmoji(scalar.value) { hasEmojiScalar = true }
            if ReixUnicode16Tables.graphemeBreak(scalar.value) == .regionalIndicator {
                regionalScalars += 1
            }
            if isWide(scalar.value) || isExtendedPictograph(scalar.value) {
                width = 2
                hasVisibleScalar = true
            } else if scalar.value == 0xFE0F && hasEmojiScalar {
                width = 2
                hasVisibleScalar = true
            } else if !isZeroWidth(scalar.value) {
                if width == 0 { width = 1 }
                hasVisibleScalar = true
            }
            cursor += scalar.length
        }
        if regionalScalars >= 2 { return 2 }
        return hasVisibleScalar ? width : 1
    }

    public static func position(
        at target: Int,
        count: Int,
        columns: UInt16,
        byte: (Int) -> UInt8?
    ) -> Position? {
        guard columns > 0, target >= 0, target <= count else { return nil }
        var row: UInt16 = 0
        var column: UInt16 = 0
        var cursor = 0
        while cursor < target {
            guard let end = nextGraphemeBoundary(after: cursor, count: count, byte: byte),
                  end <= target,
                  let first = decode(at: cursor, count: count, byte: byte)
            else { return nil }
            if first.value == 0x0A {
                guard row < UInt16.max else { return nil }
                row += 1
                column = 0
            } else {
                guard let width = cellWidth(from: cursor, to: end, count: count, byte: byte),
                      width <= columns
                else { return nil }
                if column > 0 && width > columns - column {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = 0
                }
                column += width
                if column == columns {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = 0
                }
            }
            cursor = end
        }
        return cursor == target ? Position(row: row, column: column) : nil
    }

    public static func byteOffset(
        row targetRow: UInt16,
        column targetColumn: UInt16,
        count: Int,
        columns: UInt16,
        byte: (Int) -> UInt8?
    ) -> Int? {
        guard let offset = closestByteOffset(
            row: targetRow,
            column: targetColumn,
            count: count,
            columns: columns,
            byte: byte
        ),
              position(at: offset, count: count, columns: columns, byte: byte)
                == Position(row: targetRow, column: targetColumn)
        else { return nil }
        return offset
    }

    public static func closestByteOffset(
        row targetRow: UInt16,
        column targetColumn: UInt16,
        count: Int,
        columns: UInt16,
        byte: (Int) -> UInt8?
    ) -> Int? {
        guard columns > 0, targetColumn < columns else { return nil }
        var row: UInt16 = 0
        var column: UInt16 = 0
        var offset = 0
        var candidate: Int?
        while offset <= count {
            if row == targetRow && column <= targetColumn { candidate = offset }
            if row > targetRow || offset == count { break }
            guard let end = nextGraphemeBoundary(after: offset, count: count, byte: byte),
                  let first = decode(at: offset, count: count, byte: byte),
                  let width = cellWidth(from: offset, to: end, count: count, byte: byte),
                  width <= columns
            else { return nil }
            if first.value == 0x0A {
                guard row < UInt16.max else { return nil }
                row += 1
                column = 0
            } else {
                if column > 0 && width > columns - column {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = 0
                }
                column += width
                if column == columns {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = 0
                }
            }
            offset = end
        }
        return candidate
    }

    private static func decode(
        at offset: Int,
        count: Int,
        byte: (Int) -> UInt8?
    ) -> Scalar? {
        guard offset >= 0, offset < count, let first = byte(offset) else { return nil }
        if first < 0x80 { return Scalar(value: UInt32(first), length: 1) }
        let length: Int
        let minimum: UInt32
        var value: UInt32
        switch first {
            case 0xC2...0xDF:
                length = 2
                minimum = 0x80
                value = UInt32(first & 0x1F)
            case 0xE0...0xEF:
                length = 3
                minimum = 0x800
                value = UInt32(first & 0x0F)
            case 0xF0...0xF4:
                length = 4
                minimum = 0x1_0000
                value = UInt32(first & 0x07)
            default:
                return nil
        }
        guard offset <= count - length else { return nil }
        for index in 1..<length {
            guard let continuation = byte(offset + index), continuation & 0xC0 == 0x80 else {
                return nil
            }
            value = value << 6 | UInt32(continuation & 0x3F)
        }
        guard value >= minimum,
              value <= 0x10_FFFF,
              value < 0xD800 || value > 0xDFFF
        else { return nil }
        return Scalar(value: value, length: length)
    }

    private static func joins(
        previous: ReixUnicode16Tables.GraphemeBreak,
        next: ReixUnicode16Tables.GraphemeBreak,
        nextValue: UInt32,
        regionalCount: Int,
        emojiState: EmojiJoinState,
        indicState: IndicJoinState,
        nextIndic: ReixUnicode16Tables.IndicConjunct
    ) -> Bool {
        if previous == .cr && next == .lf { return true }
        if previous == .cr || previous == .lf || previous == .control
            || next == .cr || next == .lf || next == .control {
            return false
        }
        if hangulJoins(previous, next) { return true }
        if next == .extend || next == .zwj || next == .spacingMark { return true }
        if previous == .prepend { return true }
        if indicState == .linked && nextIndic == .consonant { return true }
        if previous == .zwj && emojiState == .joined && isExtendedPictograph(nextValue) { return true }
        if previous == .regionalIndicator && next == .regionalIndicator {
            return regionalCount % 2 == 1
        }
        return false
    }

    private static func hangulJoins(
        _ previous: ReixUnicode16Tables.GraphemeBreak,
        _ next: ReixUnicode16Tables.GraphemeBreak
    ) -> Bool {
        if previous == .l && (next == .l || next == .v || next == .lv || next == .lvt) {
            return true
        }
        if (previous == .lv || previous == .v) && (next == .v || next == .t) {
            return true
        }
        return (previous == .lvt || previous == .t) && next == .t
    }

    private static func advanceEmoji(
        _ state: EmojiJoinState,
        value: UInt32,
        property: ReixUnicode16Tables.GraphemeBreak
    ) -> EmojiJoinState {
        if isExtendedPictograph(value) { return .pictograph }
        if property == .extend && state == .pictograph { return .pictograph }
        if property == .zwj && state == .pictograph { return .joined }
        return .none
    }

    private static func advanceIndic(
        _ state: IndicJoinState,
        property: ReixUnicode16Tables.IndicConjunct
    ) -> IndicJoinState {
        switch property {
            case .consonant: return .consonant
            case .extend: return state
            case .linker:
                return state == .consonant || state == .linked ? .linked : .none
            case .none: return .none
        }
    }

    private static func isControl(_ value: UInt32) -> Bool {
        let property = ReixUnicode16Tables.graphemeBreak(value)
        return property == .cr || property == .lf || property == .control
    }

    private static func isZeroWidth(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.isZeroWidth(value)
    }

    private static func isExtend(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.graphemeBreak(value) == .extend
    }

    private static func isSpacingMark(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.graphemeBreak(value) == .spacingMark
    }

    private static func isPrepend(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.graphemeBreak(value) == .prepend
    }

    private static func isRegional(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.graphemeBreak(value) == .regionalIndicator
    }

    private static func isExtendedPictograph(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.isExtendedPictographic(value)
    }

    private static func isWide(_ value: UInt32) -> Bool {
        ReixUnicode16Tables.isWide(value)
    }
}
