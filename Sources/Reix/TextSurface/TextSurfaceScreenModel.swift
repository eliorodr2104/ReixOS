//
//  TextSurfaceScreenModel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

/// What the terminal is showing: a transcript that flows, and the editor block
/// pinned directly below it.
///
/// The transcript is not stored. Once its bytes have been written they belong to
/// the terminal's own scrollback, and the only thing worth remembering about them
/// is where the cursor ended up. What is stored is the editor: a bounded mirror of
/// the text the producer is editing, because that block is repainted in place and
/// a patch has to be applied to something.
public struct TextSurfaceScreenModel {
    public enum ApplyResult: Equatable {
        case ready
        case duplicate
        case resynchronizationRequired
    }

    /// Where an editor block lands, and what has to happen to the screen first.
    public struct Placement: Equatable {
        /// One-based physical row of the block's first viewport row.
        public let anchorRow: UInt16
        /// A partial transcript line has to be closed before the block starts.
        public let breakLine: Bool
        /// Line feeds owed at the bottom row so the block fits on screen.
        public let scrollRows: UInt16

        public init(
            anchorRow : UInt16,
            breakLine : Bool,
            scrollRows: UInt16
        ) {
            self.anchorRow = anchorRow
            self.breakLine = breakLine
            self.scrollRows = scrollRows
        }
    }

    /// The terminal position after an external record and, when an editor is
    /// visible, the new position at which that unchanged editor is redrawn.
    public struct ExternalOutputPlan: Equatable {
        public let outputRow      : UInt16
        public let outputColumn   : UInt16
        public let editorPlacement: Placement?

        public init(
            outputRow      : UInt16,
            outputColumn   : UInt16,
            editorPlacement: Placement?
        ) {
            self.outputRow = outputRow
            self.outputColumn = outputColumn
            self.editorPlacement = editorPlacement
        }
    }

    public private(set) var columns : UInt16 = 80
    public private(set) var rows    : UInt16 = 24
    public private(set) var mode    = ReixTextSurfaceFrameMode.transcript

    /// One-based row and zero-based column where the transcript will continue.
    ///
    /// It starts at the last row because that is where a terminal leaves the
    /// cursor after anything has been printed to it, and the adapter parks it
    /// there for the cases where nothing has.
    public private(set) var flowRow   : UInt16 = 24
    public private(set) var flowColumn: UInt16 = 0

    public private(set) var editorPainted   = false
    public private(set) var editorAnchorRow : UInt16 = 1
    public private(set) var editorRows      : UInt16 = 0

    public private(set) var cursorRow: UInt16 = 0
    public private(set) var cursorColumn: UInt16 = 0
    public private(set) var viewportRow: UInt16 = 0
    public private(set) var viewportRows: UInt16 = 1
    public private(set) var overlayRow: UInt16 = 0
    public private(set) var overlayColumn: UInt16 = 0
    public private(set) var overlayRows: UInt16 = 0
    public private(set) var overlayColumns: UInt16 = 0
    public private(set) var revision: UInt32 = 0
    public private(set) var requiresResynchronization = false
    public private(set) var textLength = 0
    public private(set) var overlayLength = 0
    public private(set) var styleSpanCount = 0
    public private(set) var overlayStyleSpanCount = 0

    private var text = InlineArray<8200, UInt8>(repeating: 0)
    private var overlay = InlineArray<1024, UInt8>(repeating: 0)
    private var styles = InlineArray<32, ReixTextSurfaceStyleSpan>(
        repeating: ReixTextSurfaceStyleSpan(offset: 0, length: 1, role: .plain)!
    )
    private var overlayStyles = InlineArray<16, ReixTextSurfaceStyleSpan>(
        repeating: ReixTextSurfaceStyleSpan(offset: 0, length: 1, role: .plain)!
    )
    private var committedChecksum: UInt32 = 0

    private static let lineFeed: UInt8 = 0x0A

    public init() {}

    public var interactiveRows: UInt16 {
        ReixTextSurfaceFrameDescriptor.interactiveRows(for: rows)
    }

    public func textByte(at index: Int) -> UInt8? {
        guard index >= 0, index < textLength else { return nil }
        return text[index]
    }

    public func overlayByte(at index: Int) -> UInt8? {
        guard index >= 0, index < overlayLength else { return nil }
        return overlay[index]
    }

    public func styleSpan(at index: Int) -> ReixTextSurfaceStyleSpan? {
        guard index >= 0, index < styleSpanCount else { return nil }
        return styles[index]
    }

    public func overlayStyleSpan(at index: Int) -> ReixTextSurfaceStyleSpan? {
        guard index >= 0, index < overlayStyleSpanCount else { return nil }
        return overlayStyles[index]
    }

    /// A frame that changes the geometry cannot be placed against the old one: the
    /// terminal has reflowed and no remembered row still means what it meant.
    /// The cursor goes back to the last row, which is the one place a terminal can
    /// be sent to without knowing how big it is.
    public func reparks(_ frame: ReixTextSurfaceFrameView) -> Bool {
        frame.descriptor.columns != columns || frame.descriptor.rows != rows
    }

    /// Where this frame's editor block lands. Renderer and model both ask, so the
    /// bytes that go out and the state that is remembered cannot drift apart.
    public func placement(for frame: ReixTextSurfaceFrameView) -> Placement {
        let descriptor = frame.descriptor
        let parked     = reparks(frame)
        if !parked, editorPainted {
            let height = min(max(1, descriptor.viewportRows), descriptor.rows)
            let bottom = min(descriptor.rows, editorAnchorRow + editorRows - 1)
            return Placement(
                anchorRow: bottom >= height ? bottom - height + 1 : 1,
                breakLine: false,
                scrollRows: 0
            )
        }
        return Self.placement(
            flowRow: parked ? descriptor.rows : flowRow,
            flowColumn: parked ? 0 : flowColumn,
            rows: descriptor.rows,
            height: descriptor.viewportRows
        )
    }

    /// Validates and measures a semantic record without changing the editor or
    /// the committed surface revision. Control graphemes are presented as one
    /// replacement cell, matching the renderer and preventing embedded VT.
    public func planExternalOutput(_ record: ReixTextOutputRecord) -> ExternalOutputPlan? {
        guard ReixTextLayout.validUTF8(
            count: record.payloadCount,
            byte: record.payloadByte
        ) else { return nil }

        var row    = flowRow
        var column = flowColumn
        var offset = 0
        while offset < record.payloadCount {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: record.payloadCount,
                byte: record.payloadByte
            ),
                  let first = record.payloadByte(at: offset)
            else { return nil }
            if first == Self.lineFeed {
                Self.nextFlowRow(row: &row, column: &column, rows: rows)
            } else {
                let width: UInt16
                if Self.isControl(
                    first: first,
                    second: offset + 1 < end ? record.payloadByte(at: offset + 1) : nil
                ) {
                    width = 1
                } else {
                    guard let measured = ReixTextLayout.cellWidth(
                        from: offset,
                        to: end,
                        count: record.payloadCount,
                        byte: record.payloadByte
                    ), measured <= columns else { return nil }
                    width = measured
                }
                if column > 0, width > columns - column {
                    Self.nextFlowRow(row: &row, column: &column, rows: rows)
                }
                column += width
                if column == columns {
                    Self.nextFlowRow(row: &row, column: &column, rows: rows)
                }
            }
            offset = end
        }

        let editorPlacement = editorPainted
            ? Self.placement(
                flowRow: row,
                flowColumn: column,
                rows: rows,
                height: editorRows
            )
            : nil

        return ExternalOutputPlan(
            outputRow: row,
            outputColumn: column,
            editorPlacement: editorPlacement
        )
    }

    /// Commits only the physical placement calculated for an external record.
    /// The user's bytes, cursor, selection styles, overlay, and revision remain
    /// exactly as they were before the record arrived.
    public mutating func commitExternalOutput(_ plan: ExternalOutputPlan) {
        if let placement = plan.editorPlacement {
            flowRow = placement.anchorRow
            flowColumn = 0
            editorAnchorRow = placement.anchorRow
        } else {
            flowRow = plan.outputRow
            flowColumn = plan.outputColumn
        }
    }

    private static func placement(
        flowRow               : UInt16,
        flowColumn            : UInt16,
        rows                  : UInt16,
        height requestedHeight: UInt16
    ) -> Placement {
        let limit     = rows
        let height    = min(max(1, requestedHeight), limit)
        let row       = min(max(1, flowRow), limit)
        let column    = flowColumn
        let breakLine = column > 0
        let top       = breakLine ? min(row + 1, limit) : row
        let bottom    = top + height - 1
        let scroll    = bottom > limit ? bottom - limit : 0
        return Placement(
            anchorRow: top - min(scroll, top - 1),
            breakLine: breakLine,
            scrollRows: min(scroll, top - 1)
        )
    }

    private static func isControl(
        first : UInt8,
        second: UInt8?
    ) -> Bool {
        let c1 = first == 0xC2 && second.map { $0 >= 0x80 && $0 <= 0x9F } == true
        return first < 0x20 || first == 0x7F || c1
    }

    private static func nextFlowRow(
        row   : inout UInt16,
        column: inout UInt16,
        rows  : UInt16
    ) {
        if row < rows { row += 1 }
        column = 0
    }

    public mutating func prepare(_ frame: ReixTextSurfaceFrameView) -> ApplyResult {
        if frame.descriptor.revision == revision {
            guard frame.checksum == committedChecksum else {
                requiresResynchronization = true
                return .resynchronizationRequired
            }
            return .duplicate
        }
        guard accepts(frame), valid(frame) else {
            requiresResynchronization = true
            return .resynchronizationRequired
        }
        return .ready
    }

    public mutating func commit(_ frame: ReixTextSurfaceFrameView) -> Bool {
        guard prepare(frame) == .ready else { return false }
        let descriptor = frame.descriptor
        if reparks(frame) {
            columns = descriptor.columns
            rows = descriptor.rows
            flowRow = rows
            flowColumn = 0
            retireEditor()
        }
        switch descriptor.mode {
            case .transcript:
                retireEditor()
                advanceFlow(frame)
            case .codeTranscript:
                retireEditor()
                advanceCodeTranscript(frame)
            case .editor, .codeEditor:
                let placement = placement(for: frame)
                applyEditorText(frame)
                applySpans(frame)
                cursorRow = descriptor.cursorRow
                cursorColumn = descriptor.cursorColumn
                viewportRow = descriptor.viewportRow
                viewportRows = descriptor.viewportRows
                overlayRow = descriptor.overlayRow
                overlayColumn = descriptor.overlayColumn
                overlayRows = descriptor.overlayRows
                overlayColumns = descriptor.overlayColumns
                flowRow = placement.anchorRow
                flowColumn = 0
                editorPainted = true
                editorAnchorRow = placement.anchorRow
                editorRows = min(max(1, descriptor.viewportRows), rows)
        }
        mode = descriptor.mode
        revision = descriptor.revision
        committedChecksum = frame.checksum
        requiresResynchronization = false
        return true
    }

    public mutating func requireSnapshot() {
        requiresResynchronization = true
    }

    public func desiredTextLength(for frame: ReixTextSurfaceFrameView) -> Int {
        if frame.descriptor.kind == .snapshot { return Int(frame.descriptor.textLength) }
        return textLength - Int(frame.descriptor.replacedLength) + Int(frame.descriptor.textLength)
    }

    public func desiredTextByte(at index: Int, for frame: ReixTextSurfaceFrameView) -> UInt8? {
        guard index >= 0, index < desiredTextLength(for: frame) else { return nil }
        if frame.descriptor.kind == .snapshot { return frame.textByte(at: index) }
        let offset = Int(frame.descriptor.patchOffset)
        let inserted = Int(frame.descriptor.textLength)
        if index < offset { return text[index] }
        if index < offset + inserted { return frame.textByte(at: index - offset) }
        return text[index - inserted + Int(frame.descriptor.replacedLength)]
    }

    /// The editor block is gone from the screen; the transcript owns those rows.
    private mutating func retireEditor() {
        editorPainted = false
        editorRows = 0
        textLength = 0
        styleSpanCount = 0
        overlayLength = 0
        overlayStyleSpanCount = 0
    }

    private mutating func applyEditorText(_ frame: ReixTextSurfaceFrameView) {
        let descriptor = frame.descriptor
        if descriptor.kind == .snapshot {
            textLength = Int(descriptor.textLength)
            for index in 0..<textLength { text[index] = frame.textByte(at: index)! }
            return
        }
        let offset    = Int(descriptor.patchOffset)
        let removed   = Int(descriptor.replacedLength)
        let inserted  = Int(descriptor.textLength)
        let tailStart = offset + removed
        let tailCount = textLength - tailStart
        if inserted > removed {
            var index = tailCount
            while index > 0 {
                index -= 1
                text[offset + inserted + index] = text[tailStart + index]
            }
        } else if inserted < removed {
            for index in 0..<tailCount { text[offset + inserted + index] = text[tailStart + index] }
        }
        for index in 0..<inserted { text[offset + index] = frame.textByte(at: index)! }
        textLength = textLength - removed + inserted
    }

    private mutating func applySpans(_ frame: ReixTextSurfaceFrameView) {
        let descriptor = frame.descriptor
        styleSpanCount = Int(descriptor.styleSpanCount)
        for index in 0..<styleSpanCount { styles[index] = frame.styleSpan(at: index)! }
        overlayLength = Int(descriptor.overlayLength)
        for index in 0..<overlayLength { overlay[index] = frame.overlayByte(at: index)! }
        overlayStyleSpanCount = Int(descriptor.overlayStyleSpanCount)
        for index in 0..<overlayStyleSpanCount {
            overlayStyles[index] = frame.overlayStyleSpan(at: index)!
        }
    }

    /// Walks the appended text the way the terminal will, so the flow cursor this
    /// model reports is the one the screen actually has.
    private mutating func advanceFlow(_ frame: ReixTextSurfaceFrameView) {
        let length = Int(frame.descriptor.textLength)
        var offset = 0
        while offset < length {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: length,
                byte: { frame.textByte(at: $0) }
            ),
                  let first = frame.textByte(at: offset),
                  let width = ReixTextLayout.cellWidth(
                      from: offset,
                      to: end,
                      count: length,
                      byte: { frame.textByte(at: $0) }
                  ),
                  width <= columns
            else { return }
            if first == Self.lineFeed {
                nextFlowRow()
            } else {
                if flowColumn > 0, width > columns - flowColumn { nextFlowRow() }
                flowColumn += width
                if flowColumn == columns { nextFlowRow() }
            }
            offset = end
        }
    }

    private mutating func advanceCodeTranscript(_ frame: ReixTextSurfaceFrameView) {
        let length = Int(frame.descriptor.textLength)
        guard let end = ReixCodeEditorLayout.position(
            at: length,
            count: length,
            columns: columns,
            byte: { frame.textByte(at: $0) }
        ) else { return }
        flowColumn = 0
        for _ in 0...end.row { nextFlowRow() }
    }

    private mutating func nextFlowRow() {
        if flowRow < rows { flowRow += 1 }
        flowColumn = 0
    }

    private func accepts(_ frame: ReixTextSurfaceFrameView) -> Bool {
        guard let expected = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision),
              frame.descriptor.revision == expected
        else { return false }
        if frame.descriptor.kind == .snapshot {
            return frame.descriptor.baseRevision == 0
        }
        return !requiresResynchronization && revision != 0 && frame.descriptor.baseRevision == revision
    }

    private func valid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor = frame.descriptor
        guard !reparks(frame) || descriptor.kind == .snapshot,
              descriptor.viewportRows <= descriptor.rows
        else { return false }
        guard ReixTextLayout.validUTF8(
            count: Int(descriptor.textLength),
            byte: { frame.textByte(at: $0) }
        ) else { return false }
        guard descriptor.mode != .transcript,
              descriptor.mode != .codeTranscript
        else { return transcriptValid(frame) }
        if descriptor.kind == .patch {
            guard mode == descriptor.mode,
                  descriptor.columns == columns,
                  descriptor.rows == rows,
                  Int(descriptor.patchOffset) <= textLength,
                  Int(descriptor.replacedLength) <= textLength - Int(descriptor.patchOffset),
                  boundary(Int(descriptor.patchOffset)),
                  boundary(Int(descriptor.patchOffset + descriptor.replacedLength))
            else { return false }
        }
        let resultLength = desiredTextLength(for: frame)
        guard resultLength >= 0,
              resultLength <= ReixTextSurfaceFrameDescriptor.maximumTextBytes,
              spansValid(frame, count: Int(descriptor.styleSpanCount), limit: resultLength, overlay: false),
              spansValid(
                  frame,
                  count: Int(descriptor.overlayStyleSpanCount),
                  limit: Int(descriptor.overlayLength),
                  overlay: true
              ),
              overlayValid(frame),
              cursorValid(frame)
        else { return false }
        return true
    }

    /// An appended chunk stands on its own: its spans measure the chunk, and the
    /// only screen state it may disturb is the flow cursor.
    private func transcriptValid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor  = frame.descriptor
        var previousEnd = 0
        for index in 0..<Int(descriptor.styleSpanCount) {
            guard let span = frame.styleSpan(at: index) else { return false }
            let start = Int(span.offset)
            let end   = start + Int(span.length)
            guard start >= previousEnd,
                  end <= Int(descriptor.textLength),
                  chunkBoundary(start, frame: frame),
                  chunkBoundary(end, frame: frame)
            else { return false }
            previousEnd = end
        }
        return true
    }

    private func chunkBoundary(
        _ index: Int,
        frame  : ReixTextSurfaceFrameView
    ) -> Bool {
        let length = Int(frame.descriptor.textLength)
        guard index >= 0, index <= length else { return false }
        return ReixTextLayout.isGraphemeBoundary(index, count: length) { frame.textByte(at: $0) }
    }

    private func boundary(_ index: Int) -> Bool {
        ReixTextLayout.isGraphemeBoundary(index, count: textLength) { text[$0] }
    }

    private func spansValid(
        _ frame: ReixTextSurfaceFrameView,
        count: Int,
        limit: Int,
        overlay: Bool
    ) -> Bool {
        var previousEnd = 0
        for index in 0..<count {
            let span = overlay ? frame.overlayStyleSpan(at: index) : frame.styleSpan(at: index)
            guard let span else { return false }
            let end = Int(span.offset) + Int(span.length)
            let startBoundary = overlay
                ? overlayBoundary(Int(span.offset), frame: frame)
                : desiredBoundary(Int(span.offset), frame: frame)
            let endBoundary = overlay
                ? overlayBoundary(end, frame: frame)
                : desiredBoundary(end, frame: frame)
            guard Int(span.offset) >= previousEnd,
                  end <= limit,
                  startBoundary,
                  endBoundary
            else { return false }
            previousEnd = end
        }
        return true
    }

    private func desiredBoundary(_ index: Int, frame: ReixTextSurfaceFrameView) -> Bool {
        let length = desiredTextLength(for: frame)
        guard index >= 0, index <= length else { return false }
        return ReixTextLayout.isGraphemeBoundary(index, count: length) {
            desiredTextByte(at: $0, for: frame)
        }
    }

    private func overlayBoundary(_ index: Int, frame: ReixTextSurfaceFrameView) -> Bool {
        let length = Int(frame.descriptor.overlayLength)
        guard index >= 0, index <= length else { return false }
        return ReixTextLayout.isGraphemeBoundary(index, count: length) { frame.overlayByte(at: $0) }
    }

    private func overlayValid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor = frame.descriptor
        guard descriptor.overlayLength > 0 else { return true }
        guard ReixTextLayout.validUTF8(
            count: Int(descriptor.overlayLength),
            byte: { frame.overlayByte(at: $0) }
        ) else { return false }
        guard let position = ReixTextLayout.position(
            at: Int(descriptor.overlayLength),
            count: Int(descriptor.overlayLength),
            columns: descriptor.overlayColumns,
            byte: { frame.overlayByte(at: $0) }
        ) else { return false }
        return position.row < descriptor.overlayRows
            || position.row == descriptor.overlayRows && position.column == 0
    }

    private func cursorValid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor = frame.descriptor
        let length = desiredTextLength(for: frame)
        if descriptor.mode == .codeEditor {
            return ReixCodeEditorLayout.byteOffset(
                row: descriptor.cursorRow,
                column: descriptor.cursorColumn,
                count: length,
                columns: descriptor.columns,
                byte: { desiredTextByte(at: $0, for: frame) }
            ) != nil
        }
        return ReixTextLayout.byteOffset(
            row: descriptor.cursorRow,
            column: descriptor.cursorColumn,
            count: length,
            columns: descriptor.columns,
            byte: { desiredTextByte(at: $0, for: frame) }
        ) != nil
    }
}
