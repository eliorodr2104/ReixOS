//
//  ReixCodeEditorLayout.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

/// Maps the script buffer to the semantic code-editor scene. The header and
/// gutter are presentation chrome: they consume cells, and the user's command
/// is made of the script buffer alone.
public enum ReixCodeEditorLayout {
    public static let headerRows           : UInt16 = 1
    public static let footerRowCount       : UInt16 = 1
    public static let standardGutterColumns: UInt16 = 7

    /// The shortcut bar is useful only when the surface can still show both
    /// the title and one editable row. Tiny recovery terminals keep the code
    /// reachable and omit the footer.
    public static func footerRows(for availableRows: UInt16) -> UInt16 {
        availableRows >= 3 ? footerRowCount : 0
    }

    public static func contentViewportRows(for viewportRows: UInt16) -> UInt16 {
        let chromeRows = headerRows + footerRows(for: viewportRows)
        return viewportRows > chromeRows ? viewportRows - chromeRows : 0
    }

    /// The title and shortcut bar are fixed chrome. `viewportRow` scrolls only
    /// document rows, whose coordinates begin immediately below the title.
    public static func firstVisibleContentRow(viewportRow: UInt16) -> UInt16 {
        viewportRow < headerRows ? headerRows : viewportRow
    }

    public static func surfaceRow(
        for documentRow: UInt16,
        viewportRow    : UInt16,
        viewportRows   : UInt16
    ) -> UInt16? {
        let first   = firstVisibleContentRow(viewportRow: viewportRow)
        let visible = contentViewportRows(for: viewportRows)
        guard visible > 0,
              documentRow >= first,
              documentRow - first < visible
        else { return nil }
        return headerRows + documentRow - first
    }

    /// Full terminals use `0000 | `. Very narrow test or recovery terminals use
    /// a compact one-digit gutter while still leaving at least one editing cell.
    public static func gutterColumns(for columns: UInt16) -> UInt16 {
        if columns > standardGutterColumns { return standardGutterColumns }
        if columns > 3 { return 3 }
        return 0
    }

    public static func position(
        at target: Int,
        count    : Int,
        columns  : UInt16,
        byte     : (Int) -> UInt8?
    ) -> ReixTextLayout.Position? {
        guard columns > 0, target >= 0, target <= count else { return nil }
        let gutter = gutterColumns(for: columns)
        var row    = headerRows
        var column = gutter
        var offset = 0
        while offset < target {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: count,
                byte: byte
            ),
                  end <= target,
                  let first = byte(offset)
            else { return nil }
            if first == 0x0A {
                guard row < UInt16.max else { return nil }
                row += 1
                column = gutter
            } else {
                guard let width = ReixTextLayout.cellWidth(
                    from: offset,
                    to: end,
                    count: count,
                    byte: byte
                ),
                      width <= columns - gutter
                else { return nil }
                if column > gutter && width > columns - column {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = gutter
                }
                column += width
                if column == columns {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = gutter
                }
            }
            offset = end
        }
        return offset == target ? ReixTextLayout.Position(row: row, column: column) : nil
    }

    public static func byteOffset(
        row targetRow      : UInt16,
        column targetColumn: UInt16,
        count              : Int,
        columns            : UInt16,
        byte               : (Int) -> UInt8?
    ) -> Int? {
        guard columns > 0, targetColumn < columns else { return nil }
        let gutter = gutterColumns(for: columns)
        var row    = headerRows
        var column = gutter
        var offset = 0
        if row == targetRow && column == targetColumn { return 0 }
        while offset < count {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: count,
                byte: byte
            ),
                  let first = byte(offset)
            else { return nil }
            if first == 0x0A {
                guard row < UInt16.max else { return nil }
                row += 1
                column = gutter
            } else {
                guard let width = ReixTextLayout.cellWidth(
                    from: offset,
                    to: end,
                    count: count,
                    byte: byte
                ),
                      width <= columns - gutter
                else { return nil }
                if column > gutter && width > columns - column {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = gutter
                }
                column += width
                if column == columns {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = gutter
                }
            }
            offset = end
            if row == targetRow && column == targetColumn { return offset }
        }
        return nil
    }

    public static func closestByteOffset(
        row targetRow      : UInt16,
        column targetColumn: UInt16,
        count              : Int,
        columns            : UInt16,
        byte               : (Int) -> UInt8?
    ) -> Int? {
        guard columns > 0, targetColumn < columns else { return nil }
        let gutter    = gutterColumns(for: columns)
        var row       = headerRows
        var column    = gutter
        var offset    = 0
        var candidate : Int?
        while offset <= count {
            if row == targetRow && column <= targetColumn { candidate = offset }
            if row > targetRow || offset == count { break }
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: count,
                byte: byte
            ),
                  let first = byte(offset)
            else { return nil }
            if first == 0x0A {
                guard row < UInt16.max else { return nil }
                row += 1
                column = gutter
            } else {
                guard let width = ReixTextLayout.cellWidth(
                    from: offset,
                    to: end,
                    count: count,
                    byte: byte
                ),
                      width <= columns - gutter
                else { return nil }
                if column > gutter && width > columns - column {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = gutter
                }
                column += width
                if column == columns {
                    guard row < UInt16.max else { return nil }
                    row += 1
                    column = gutter
                }
            }
            offset = end
        }
        return candidate
    }
}
