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

        for index in 0..<shown {
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
        if panel.truncated {
            put(" · more")
            columnsWritten += 7
        }
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
}
