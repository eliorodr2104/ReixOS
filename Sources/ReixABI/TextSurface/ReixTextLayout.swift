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

    public static func validUTF8(
        count: Int,
        byte: (Int) -> UInt8?
    ) -> Bool {
        guard count >= 0 else { return false }
        var offset = 0
        while offset < count {
            guard let scalar = decode(at: offset, count: count, byte: byte) else { return false }
            if scalar.value < 0x20 && scalar.value != 0x0A { return false }
            if scalar.value >= 0x7F && scalar.value <= 0x9F { return false }
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
        var previous = first.value
        var regionalCount = isRegional(first.value) ? 1 : 0
        var hasExtendedPictograph = isExtendedPictograph(first.value)
        while cursor < count {
            guard let next = decode(at: cursor, count: count, byte: byte) else { return nil }
            let joins = joins(
                previous: previous,
                next: next.value,
                regionalCount: regionalCount,
                hasExtendedPictograph: hasExtendedPictograph
            )
            if !joins { break }
            if isRegional(next.value) { regionalCount += 1 }
            else if !isExtend(next.value) { regionalCount = 0 }
            if isExtendedPictograph(next.value) { hasExtendedPictograph = true }
            previous = next.value
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
        while cursor < end {
            guard let scalar = decode(at: cursor, count: count, byte: byte) else { return nil }
            if scalar.value == 0x0A { return 0 }
            if isWide(scalar.value) || isExtendedPictograph(scalar.value) {
                width = 2
                hasVisibleScalar = true
            } else if !isZeroWidth(scalar.value) {
                if width == 0 { width = 1 }
                hasVisibleScalar = true
            }
            cursor += scalar.length
        }
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
        previous: UInt32,
        next: UInt32,
        regionalCount: Int,
        hasExtendedPictograph: Bool
    ) -> Bool {
        if previous == 0x0D && next == 0x0A { return true }
        if isControl(previous) || isControl(next) { return false }
        if hangulJoins(previous, next) { return true }
        if isExtend(next) || next == 0x200D || isSpacingMark(next) { return true }
        if isPrepend(previous) { return true }
        if previous == 0x200D && hasExtendedPictograph && isExtendedPictograph(next) { return true }
        if isRegional(previous) && isRegional(next) { return regionalCount % 2 == 1 }
        return false
    }

    private static func hangulJoins(_ previous: UInt32, _ next: UInt32) -> Bool {
        let previousL = isHangulL(previous)
        let previousV = isHangulV(previous)
        let previousT = isHangulT(previous)
        let previousLV = isHangulLV(previous)
        let previousLVT = isHangulLVT(previous)
        if previousL && (isHangulL(next) || isHangulV(next) || isHangulLV(next) || isHangulLVT(next)) {
            return true
        }
        if (previousLV || previousV) && (isHangulV(next) || isHangulT(next)) { return true }
        return (previousLVT || previousT) && isHangulT(next)
    }

    private static func isControl(_ value: UInt32) -> Bool {
        value <= 0x1F || value >= 0x7F && value <= 0x9F
    }

    private static func isZeroWidth(_ value: UInt32) -> Bool {
        isExtend(value) || value == 0x200D || isControl(value)
    }

    private static func isExtend(_ value: UInt32) -> Bool {
        value >= 0x0300 && value <= 0x036F
            || value >= 0x0483 && value <= 0x0489
            || value >= 0x0591 && value <= 0x05BD
            || value >= 0x0610 && value <= 0x061A
            || value >= 0x064B && value <= 0x065F
            || value >= 0x1AB0 && value <= 0x1AFF
            || value >= 0x1DC0 && value <= 0x1DFF
            || value >= 0x20D0 && value <= 0x20FF
            || value >= 0xFE00 && value <= 0xFE0F
            || value >= 0xFE20 && value <= 0xFE2F
            || value >= 0xE0100 && value <= 0xE01EF
            || value >= 0x1F3FB && value <= 0x1F3FF
    }

    private static func isSpacingMark(_ value: UInt32) -> Bool {
        value == 0x0903 || value >= 0x093B && value <= 0x0940
            || value >= 0x0949 && value <= 0x094C
            || value >= 0x0BBE && value <= 0x0BC2
    }

    private static func isPrepend(_ value: UInt32) -> Bool {
        value >= 0x0600 && value <= 0x0605 || value == 0x06DD || value == 0x070F
    }

    private static func isRegional(_ value: UInt32) -> Bool {
        value >= 0x1F1E6 && value <= 0x1F1FF
    }

    private static func isExtendedPictograph(_ value: UInt32) -> Bool {
        value >= 0x1F000 && value <= 0x1FAFF
            || value >= 0x2600 && value <= 0x26FF
            || value >= 0x2700 && value <= 0x2767
            || value >= 0x2793 && value <= 0x27BF
            || value >= 0x2300 && value <= 0x23FF
    }

    private static func isWide(_ value: UInt32) -> Bool {
        value >= 0x1100 && value <= 0x115F
            || value >= 0x2329 && value <= 0x232A
            || value >= 0x2E80 && value <= 0xA4CF
            || value >= 0xAC00 && value <= 0xD7A3
            || value >= 0xF900 && value <= 0xFAFF
            || value >= 0xFE10 && value <= 0xFE6F
            || value >= 0xFF01 && value <= 0xFF60
            || value >= 0xFFE0 && value <= 0xFFE6
            || value >= 0x20000 && value <= 0x3FFFD
    }

    private static func isHangulL(_ value: UInt32) -> Bool {
        value >= 0x1100 && value <= 0x115F || value >= 0xA960 && value <= 0xA97C
    }

    private static func isHangulV(_ value: UInt32) -> Bool {
        value >= 0x1160 && value <= 0x11A7 || value >= 0xD7B0 && value <= 0xD7C6
    }

    private static func isHangulT(_ value: UInt32) -> Bool {
        value >= 0x11A8 && value <= 0x11FF || value >= 0xD7CB && value <= 0xD7FB
    }

    private static func isHangulLV(_ value: UInt32) -> Bool {
        value >= 0xAC00 && value <= 0xD7A3 && (value - 0xAC00) % 28 == 0
    }

    private static func isHangulLVT(_ value: UInt32) -> Bool {
        value >= 0xAC00 && value <= 0xD7A3 && (value - 0xAC00) % 28 != 0
    }
}
