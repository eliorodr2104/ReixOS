//
//  ShellPanelPainter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

public struct ShellPanelGeometry: Equatable {
    public let rows      : UInt16

    /// The width the overlay is declared to be, which is one more than the box
    /// is drawn. A row exactly as wide as its box wraps by itself, and then
    /// the newline that ends it counts a second time: the frame would be
    /// refused for being twice as tall as it says.
    public let columns   : UInt16
    public let byteCount : Int
    public let spanCount : Int

    /// The rows that fitted, which may be fewer than the panel holds.
    public let shownRows : Int
}

/// Draws a panel into the bytes and spans an overlay carries.
///
/// The box is chrome and the rows are content, and neither is a colour: the
/// painter writes roles, the backend paints them. Where there is no room for
/// a box there is still an answer, on one line, because a terminal too small
/// for chrome is not a terminal that deserves silence.
public enum ShellPanelPainter {
    public static let byteCapacity   = ReixTextSurfaceFrameDescriptor.maximumOverlayBytes
    public static let spanCapacity   = Int(ReixTextSurfaceFrameDescriptor.maximumOverlayStyleSpans)

    /// Below this many columns or rows the box is dropped for a single line.
    public static let minimumColumns : UInt16 = 24
    public static let minimumRows    : UInt16 = 3
    public static let maximumColumns : UInt16 = 56

    /// Draws what the shell would write next, in one row at the cursor.
    ///
    /// Nothing here is in the line: it is drawn over the empty screen after
    /// the cursor and disappears with the next revision.
    public static func ghost(
        _ text : UnsafePointer<UInt8>,
          count: Int,
          room : UInt16,
          into bytes: UnsafeMutablePointer<UInt8>,
          spans     : UnsafeMutablePointer<ReixTextSurfaceStyleSpan>
    ) -> ShellPanelGeometry? {
        guard count > 0, room > 1 else { return nil }
        let shown = min(count, min(Int(room) - 1, byteCapacity))
        guard shown > 0 else { return nil }
        for index in 0..<shown { bytes[index] = text[index] }
        guard let span = ReixTextSurfaceStyleSpan(
            offset: 0,
            length: UInt16(shown),
            role: .ghost
        ) else { return nil }
        spans[0] = span
        return ShellPanelGeometry(
            rows: 1,
            columns: UInt16(shown + 1),
            byteCount: shown,
            spanCount: 1,
            shownRows: 1
        )
    }

    public static func paint(
        _ panel  : ShellPanel,
          columns: UInt16,
          rows   : UInt16,
          into bytes: UnsafeMutablePointer<UInt8>,
          spans     : UnsafeMutablePointer<ReixTextSurfaceStyleSpan>
    ) -> ShellPanelGeometry? {
        guard !panel.isEmpty, columns > 0, rows > 0 else { return nil }

        var offset    = 0
        var spanCount = 0
        var failed    = false

        func put(_ byte: UInt8) {
            guard offset < byteCapacity else { failed = true; return }
            bytes[offset] = byte
            offset += 1
        }

        func put(_ text: StaticString) {
            for index in 0..<text.utf8CodeUnitCount { put(text.utf8Start[index]) }
        }

        func put(
            _ source: UnsafePointer<UInt8>,
            _ count : Int
        ) {
            for index in 0..<count { put(source[index]) }
        }

        /// Cells written on the row being drawn, which is not the same as
        /// bytes: the box characters are three bytes and one cell.
        var columnsWritten = 0
        var rowStart       = 0

        func beginRow() {
            columnsWritten = 0
            rowStart = offset
        }

        func cell(_ text: StaticString) {
            put(text)
            columnsWritten += 1
        }

        func ascii(_ byte: UInt8) {
            put(byte)
            columnsWritten += 1
        }

        func pad(to column: Int) {
            // Cells, not bytes: a space is one of each, and forgetting that is
            // a loop that never ends.
            while columnsWritten < column, !failed { ascii(0x20) }
        }

        func mark(
            _ role : ReixTextSurfaceStyleRole,
              from : Int,
              to    : Int
        ) {
            guard to > from, spanCount < spanCapacity,
                  let span = ReixTextSurfaceStyleSpan(
                      offset: UInt32(from),
                      length: UInt16(to - from),
                      role: role
                  )
            else { return }
            spans[spanCount] = span
            spanCount += 1
        }

        // One column is left over so a full row never wraps on its own.
        let width = min(columns > 1 ? columns - 1 : 1, maximumColumns)

        // One line, no box: a terminal this small is better served by the
        // names than by the frame around them.
        if columns < minimumColumns || rows < minimumRows {
            beginRow()
            for index in 0..<panel.count {
                guard let row = panel.row(at: index) else { continue }
                if columnsWritten > 0 { ascii(0x20) }
                let start = offset
                row.withName { name, count in
                    put(name, count)
                    columnsWritten += count
                }
                mark(index == panel.selected ? .selection : row.role, from: start, to: offset)
                if row.sensitive { ascii(0x21) }
            }
            guard !failed, columnsWritten > 0 else { return nil }
            return ShellPanelGeometry(
                rows: 1,
                columns: UInt16(min(columnsWritten + 1, Int(columns))),
                byteCount: offset,
                spanCount: spanCount,
                shownRows: panel.count
            )
        }

        let inner    = Int(width) - 2
        let shown    = min(panel.count, max(1, Int(rows) - 2))
        let nameStop = min(inner - 12, 20)

        // The window follows the selection instead of the list following the
        // window: a row selected below what fits scrolls the box down to it.
        let first = max(0, min(panel.selected - shown + 1, panel.count - shown))

        // ┌─ title ─────────┐
        beginRow()
        cell("┌")
        cell("─")
        ascii(0x20)
        let titleStart = offset
        put(panel.title)
        columnsWritten += panel.title.utf8CodeUnitCount
        mark(.editorChrome, from: titleStart, to: offset)
        ascii(0x20)
        while columnsWritten < Int(width) - 1 { cell("─") }
        cell("┐")
        put(0x0A)

        for offsetRow in 0..<shown {
            let index = first + offsetRow
            guard let row = panel.row(at: index) else { continue }
            beginRow()
            cell("│")
            ascii(0x20)
            let nameStart = offset
            row.withName { name, count in
                put(name, count)
                columnsWritten += count
            }
            let nameEnd = offset
            pad(to: max(nameStop, columnsWritten + 1))
            put(row.detail)
            columnsWritten += row.detail.utf8CodeUnitCount
            pad(to: Int(width) - 3)
            ascii(row.sensitive ? 0x21 : 0x20)
            ascii(0x20)
            cell("│")
            if index == panel.selected {
                mark(.selection, from: rowStart, to: offset)
            } else {
                mark(row.role, from: nameStart, to: nameEnd)
            }
            put(0x0A)
        }

        // └─ what the selected row is about ──┘
        beginRow()
        cell("└")
        cell("─")
        ascii(0x20)
        let footerStart = offset
        if let selection = panel.selection, selection.summary.utf8CodeUnitCount > 0 {
            put(selection.summary)
            columnsWritten += selection.summary.utf8CodeUnitCount
        }
        // Where the selection is in the whole list, which is the only honest
        // way to say that there is more above or below.
        put(" · ")
        columnsWritten += 3
        Self.decimal(panel.selected + 1, put: { put($0) }, columns: &columnsWritten)
        put(" of ")
        columnsWritten += 4
        Self.decimal(panel.available, put: { put($0) }, columns: &columnsWritten)
        mark(.editorChrome, from: footerStart, to: offset)
        if columnsWritten < Int(width) - 1 { ascii(0x20) }
        while columnsWritten < Int(width) - 1 { cell("─") }
        cell("┘")

        guard !failed else { return nil }
        return ShellPanelGeometry(
            rows: UInt16(shown + 2),
            columns: width + 1,
            byteCount: offset,
            spanCount: spanCount,
            shownRows: shown
        )
    }

    /// A number, written out, counting the cells it took.
    private static func decimal(
        _ value  : Int,
          put    : (UInt8) -> Void,
          columns: inout Int
    ) {
        var digits  = 1
        var divisor = 1
        while value / divisor >= 10 {
            divisor *= 10
            digits += 1
        }
        while divisor > 0 {
            put(UInt8(value / divisor % 10) + 0x30)
            divisor /= 10
        }
        columns += digits
    }
}
