//
//  TextSurfaceVTRenderer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

/// Deterministic local conversion from semantic screen frames to bounded VT output.
///
/// One rule holds the two modes together: the editor block sits at the flow
/// cursor, occupying the rows immediately below it, and the transcript resumes at
/// the block's first row. Nothing is addressed relative to the bottom of the
/// screen, so where the terminal actually is and where this writes cannot diverge.
public enum TextSurfaceVTRenderer {
    public struct Metrics: Equatable {
        public let fullBytes: UInt32
        public let diffBytes: UInt32
        public let usesDiff: Bool
    }

    public static func metrics(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Metrics {
        let full = renderPlan(screen: screen, frame: frame, useDiff: false) { _ in }
        guard diffEligible(screen: screen, frame: frame) else {
            return Metrics(fullBytes: full, diffBytes: full, usesDiff: false)
        }
        let diff = renderPlan(screen: screen, frame: frame, useDiff: true) { _ in }
        return Metrics(fullBytes: full, diffBytes: diff, usesDiff: diff < full)
    }

    public static func render(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        let selectedDiff = useDiff && diffEligible(screen: screen, frame: frame)
        return renderPlan(screen: screen, frame: frame, useDiff: selectedDiff, emit: emit)
    }

    /// Presents output owned by another producer while preserving the complete
    /// semantic editor scene. The output record contains no VT bytes: controls
    /// are rendered as replacement glyphs and only this backend emits escapes.
    public static func renderExternal(
        screen: TextSurfaceScreenModel,
        record: ReixTextOutputRecord,
        plan  : TextSurfaceScreenModel.ExternalOutputPlan,
        emit  : (UInt8) -> Void
    ) -> UInt32 {
        var count         : UInt32 = 0
        let redrawsEditor = screen.editorPainted && plan.editorPlacement != nil
        if redrawsEditor {
            cursorVisible(false, count: &count, emit: emit)
            eraseEditor(screen: screen, count: &count, emit: emit)
            cup(
                row: screen.flowRow,
                column: screen.flowColumn + 1,
                count: &count,
                emit: emit
            )
        }

        renderExternalPayload(record, count: &count, emit: emit)

        if let placement = plan.editorPlacement {
            openStoredBlock(
                screen: screen,
                placement: placement,
                count: &count,
                emit: emit
            )
            cup(row: placement.anchorRow, column: 1, count: &count, emit: emit)
            if screen.mode == .codeEditor {
                renderStoredCodeEditor(
                    screen: screen,
                    baseRow: placement.anchorRow,
                    count: &count,
                    emit: emit
                )
            } else {
                renderStoredText(screen: screen, count: &count, emit: emit)
            }
            renderStoredOverlay(
                screen: screen,
                baseRow: placement.anchorRow,
                count: &count,
                emit: emit
            )
            style(.plain, count: &count, emit: emit)
            let cursorSurfaceRow = screen.mode == .codeEditor
                ? ReixCodeEditorLayout.surfaceRow(
                    for: screen.cursorRow,
                    viewportRow: screen.viewportRow,
                    viewportRows: screen.viewportRows
                ) ?? ReixCodeEditorLayout.headerRows
                : screen.cursorRow - screen.viewportRow
            cup(
                row: placement.anchorRow + cursorSurfaceRow,
                column: screen.cursorColumn + 1,
                count: &count,
                emit: emit
            )
            cursorVisible(true, count: &count, emit: emit)
        }

        return count
    }

    private static func renderPlan(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        switch frame.descriptor.mode {
            case .reset:
                return renderResetPlan(count: 0, emit: emit)
            case .transcript:
                return renderTranscriptPlan(screen: screen, frame: frame, emit: emit)
            case .codeTranscript:
                return renderCodeTranscriptPlan(screen: screen, frame: frame, emit: emit)
            case .editor:
                return renderEditorPlan(
                    screen: screen,
                    frame: frame,
                    useDiff: useDiff,
                    emit: emit
                )
            case .codeEditor:
                return renderCodeEditorPlan(
                    screen: screen,
                    frame: frame,
                    useDiff: useDiff,
                    emit: emit
                )
        }
    }

    /// Erases everything and leaves the flow at the last row. The only frame whose
    /// whole meaning is what it removes, and the input belongs at the bottom
    /// whether the screen above it is full or empty.
    private static func renderResetPlan(
        count: UInt32,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        var written = count
        style(.plain, count: &written, emit: emit)
        emitted(escape, count: &written, emit: emit)
        emitted(openBracket, count: &written, emit: emit)
        emitted(UInt8(ascii: "2"), count: &written, emit: emit)
        emitted(UInt8(ascii: "J"), count: &written, emit: emit)
        cup(row: bottomRow, column: 1, count: &written, emit: emit)
        return written
    }

    /// Appended output goes where the transcript left off. If the editor is on
    /// screen its rows are given back first, because the text now owns them.
    private static func renderTranscriptPlan(
        screen: TextSurfaceScreenModel,
        frame : ReixTextSurfaceFrameView,
        emit  : (UInt8) -> Void
    ) -> UInt32 {
        var count: UInt32 = 0
        if screen.reparks(frame) {
            parkAtBottom(count: &count, emit: emit)
        } else if screen.editorPainted {
            eraseEditor(screen: screen, count: &count, emit: emit)
            cup(
                row: screen.flowRow,
                column: screen.flowColumn + 1,
                count: &count,
                emit: emit
            )
        }
        renderChunk(frame: frame, count: &count, emit: emit)
        return count
    }

    /// A submitted script remains a semantic code block in the transcript.
    /// The buffer still contains only source bytes; this backend derives the
    /// title, gutter and visual background exactly as it does for the editor.
    private static func renderCodeTranscriptPlan(
        screen: TextSurfaceScreenModel,
        frame : ReixTextSurfaceFrameView,
        emit  : (UInt8) -> Void
    ) -> UInt32 {
        var count: UInt32 = 0
        if screen.reparks(frame) {
            parkAtBottom(count: &count, emit: emit)
        } else if screen.editorPainted {
            eraseEditor(screen: screen, count: &count, emit: emit)
            cup(
                row: screen.flowRow,
                column: screen.flowColumn + 1,
                count: &count,
                emit: emit
            )
        }
        renderCodeTranscript(frame: frame, count: &count, emit: emit)
        return count
    }

    /// The block is repainted in place. A patch that only extends the last row is
    /// written where the cursor already is, which is the whole point of the diff.
    private static func renderEditorPlan(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        var count       : UInt32 = 0
        let descriptor  = frame.descriptor
        let placement   = screen.placement(for: frame)
        let anchor      = placement.anchorRow
        let height      = min(max(1, descriptor.viewportRows), descriptor.rows)
        let start       = useDiff ? Int(descriptor.patchOffset) : 0
        var startRow    = descriptor.viewportRow
        var startColumn : UInt16 = 0

        if useDiff,
           descriptor.textLength == 0,
           descriptor.replacedLength == 0,
           stylesMatch(screen: screen, frame: frame) {
            style(.plain, count: &count, emit: emit)
            cup(
                row: anchor + descriptor.cursorRow - descriptor.viewportRow,
                column: descriptor.cursorColumn + 1,
                count: &count,
                emit: emit
            )
            return count
        }

        let destructive = !useDiff
            || descriptor.patchOffset != UInt32(screen.textLength)
            || descriptor.replacedLength != 0
        let hidesCursor = destructive
        if hidesCursor { cursorVisible(false, count: &count, emit: emit) }

        if useDiff, let position = position(of: start, in: screen),
           position.row >= descriptor.viewportRow,
           position.row < descriptor.viewportRow + height {
            startRow = position.row
            startColumn = position.column
        } else {
            openBlock(
                screen: screen,
                frame: frame,
                placement: placement,
                height: height,
                count: &count,
                emit: emit
            )
        }
        cup(
            row: anchor + startRow - descriptor.viewportRow,
            column: startColumn + 1,
            count: &count,
            emit: emit
        )
        renderText(
            screen: screen,
            frame: frame,
            from: start,
            startRow: startRow,
            count: &count,
            emit: emit
        )
        // Paint the desired suffix before erasing residue. Without synchronized
        // output, erasing first shows a blank gap for the length of the suffix.
        if destructive, useDiff,
           let end = desiredPosition(at: screen.desiredTextLength(for: frame), screen: screen, frame: frame),
           end.row >= descriptor.viewportRow,
           end.row < descriptor.viewportRow + height {
            cup(
                row: anchor + end.row - descriptor.viewportRow,
                column: end.column + 1,
                count: &count,
                emit: emit
            )
            clearToViewportEnd(
                from: end.row - descriptor.viewportRow,
                rows: height,
                baseRow: anchor,
                count: &count,
                emit: emit
            )
        }
        renderOverlay(frame, baseRow: anchor, count: &count, emit: emit)
        style(.plain, count: &count, emit: emit)
        cup(
            row: anchor + descriptor.cursorRow - descriptor.viewportRow,
            column: descriptor.cursorColumn + 1,
            count: &count,
            emit: emit
        )
        if hidesCursor { cursorVisible(true, count: &count, emit: emit) }
        return count
    }

    /// Code-editor frames keep only script bytes in the surface mirror. Header,
    /// line numbers, and continuation gutters are derived from the semantic mode
    /// here, so they can never leak into the command submitted by the shell.
    private static func renderCodeEditorPlan(
        screen : TextSurfaceScreenModel,
        frame  : ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit   : (UInt8) -> Void
    ) -> UInt32 {
        var count            : UInt32 = 0
        let descriptor       = frame.descriptor
        let placement        = screen.placement(for: frame)
        let anchor           = placement.anchorRow
        let height           = min(max(1, descriptor.viewportRows), descriptor.rows)
        let contentHeight    = ReixCodeEditorLayout.contentViewportRows(for: height)
        let start            = useDiff ? Int(descriptor.patchOffset) : 0
        var startRow         = descriptor.viewportRow
        let cursorSurfaceRow = ReixCodeEditorLayout.surfaceRow(
            for: descriptor.cursorRow,
            viewportRow: descriptor.viewportRow,
            viewportRows: height
        ) ?? ReixCodeEditorLayout.headerRows

        if useDiff,
           descriptor.textLength == 0,
           descriptor.replacedLength == 0,
           stylesMatch(screen: screen, frame: frame) {
            style(.plain, count: &count, emit: emit)
            cup(
                row: anchor + cursorSurfaceRow,
                column: descriptor.cursorColumn + 1,
                count: &count,
                emit: emit
            )
            return count
        }

        let destructive = !useDiff
            || descriptor.patchOffset != UInt32(screen.textLength)
            || descriptor.replacedLength != 0
        let hidesCursor = destructive
        if hidesCursor { cursorVisible(false, count: &count, emit: emit) }

        if useDiff,
           let position = codePosition(of: start, in: screen),
           ReixCodeEditorLayout.surfaceRow(
               for: position.row,
               viewportRow: descriptor.viewportRow,
               viewportRows: height
           ) != nil {
            startRow = position.row
        } else {
            openBlock(
                screen: screen,
                frame: frame,
                placement: placement,
                height: height,
                count: &count,
                emit: emit
            )
        }

        renderCodeEditorRows(
            length: screen.desiredTextLength(for: frame),
            columns: descriptor.columns,
            viewportRow: descriptor.viewportRow,
            viewportRows: descriptor.viewportRows,
            baseRow: anchor,
            startRow: startRow,
            clearRepaintedRows: destructive && useDiff,
            byte: { screen.desiredTextByte(at: $0, for: frame) },
            role: { styleRole(at: $0, frame: frame) },
            count: &count,
            emit: emit
        )
        if destructive, useDiff,
           let end = codeDesiredPosition(
               at: screen.desiredTextLength(for: frame),
               screen: screen,
               frame: frame
           ),
           let endSurfaceRow = ReixCodeEditorLayout.surfaceRow(
               for: end.row,
               viewportRow: descriptor.viewportRow,
               viewportRows: height
           ) {
            cup(
                row: anchor + endSurfaceRow,
                column: end.column + 1,
                count: &count,
                emit: emit
            )
            clearToViewportEnd(
                from: endSurfaceRow,
                rows: ReixCodeEditorLayout.headerRows + contentHeight,
                baseRow: anchor,
                count: &count,
                emit: emit
            )
        }
        if !useDiff {
            renderCodeEditorFooter(
                columns: descriptor.columns,
                viewportRows: height,
                baseRow: anchor,
                count: &count,
                emit: emit
            )
        }
        renderOverlay(frame, baseRow: anchor, count: &count, emit: emit)
        style(.plain, count: &count, emit: emit)
        cup(
            row: anchor + cursorSurfaceRow,
            column: descriptor.cursorColumn + 1,
            count: &count,
            emit: emit
        )
        if hidesCursor { cursorVisible(true, count: &count, emit: emit) }
        return count
    }

    /// Gives the block the rows it asked for: closes a partial transcript line,
    /// scrolls if the bottom is in the way, then blanks what it is about to own.
    private static func openBlock(
        screen   : TextSurfaceScreenModel,
        frame    : ReixTextSurfaceFrameView,
        placement: TextSurfaceScreenModel.Placement,
        height   : UInt16,
        count    : inout UInt32,
        emit     : (UInt8) -> Void
    ) {
        if screen.reparks(frame) {
            parkAtBottom(count: &count, emit: emit)
        } else if screen.editorPainted {
            eraseEditor(screen: screen, count: &count, emit: emit)
            cup(
                row: screen.flowRow,
                column: screen.flowColumn + 1,
                count: &count,
                emit: emit
            )
        }
        style(.plain, count: &count, emit: emit)
        if placement.breakLine {
            emitted(carriageReturn, count: &count, emit: emit)
            emitted(lineFeed, count: &count, emit: emit)
        }
        if placement.scrollRows > 0 {
            cup(row: frame.descriptor.rows, column: 1, count: &count, emit: emit)
            for _ in 0..<placement.scrollRows {
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
            }
        }
        clearViewport(
            baseRow: placement.anchorRow,
            rows: height,
            count: &count,
            emit: emit
        )
    }

    private static func eraseEditor(
        screen: TextSurfaceScreenModel,
        count : inout UInt32,
        emit  : (UInt8) -> Void
    ) {
        guard screen.editorRows > 0, screen.editorAnchorRow <= screen.rows else { return }
        let available = screen.rows - screen.editorAnchorRow + 1
        style(.plain, count: &count, emit: emit)
        clearViewport(
            baseRow: screen.editorAnchorRow,
            rows: min(screen.editorRows, available),
            count: &count,
            emit: emit
        )
    }

    private static func openStoredBlock(
        screen   : TextSurfaceScreenModel,
        placement: TextSurfaceScreenModel.Placement,
        count    : inout UInt32,
        emit     : (UInt8) -> Void
    ) {
        style(.plain, count: &count, emit: emit)
        if placement.breakLine {
            emitted(carriageReturn, count: &count, emit: emit)
            emitted(lineFeed, count: &count, emit: emit)
        }
        if placement.scrollRows > 0 {
            cup(row: screen.rows, column: 1, count: &count, emit: emit)
            for _ in 0..<placement.scrollRows {
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
            }
        }
        clearViewport(
            baseRow: placement.anchorRow,
            rows: min(max(1, screen.editorRows), screen.rows),
            count: &count,
            emit: emit
        )
    }

    private static func diffEligible(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Bool {
        guard frame.descriptor.mode != .transcript,
              frame.descriptor.mode != .codeTranscript
        else { return false }
        return editorDiffEligible(screen: screen, frame: frame)
    }

    private static func editorDiffEligible(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Bool {
        let descriptor = frame.descriptor
        let placement  = screen.placement(for: frame)
        guard descriptor.kind == .patch,
              screen.mode == descriptor.mode,
              screen.editorPainted,
              !screen.reparks(frame),
              !placement.breakLine,
              placement.scrollRows == 0,
              placement.anchorRow == screen.editorAnchorRow,
              descriptor.overlayLength == 0,
              screen.overlayLength == 0,
              stylesMatch(screen: screen, frame: frame, before: Int(descriptor.patchOffset)),
              descriptor.viewportRow == screen.viewportRow,
              descriptor.viewportRows == screen.viewportRows
        else { return false }
        if descriptor.textLength == 0,
           descriptor.replacedLength == 0,
           stylesMatch(screen: screen, frame: frame) {
            return true
        }
        guard ReixTextLayout.isGraphemeBoundary(
                  Int(descriptor.patchOffset),
                  count: screen.desiredTextLength(for: frame),
                  byte: { screen.desiredTextByte(at: $0, for: frame) }
              ),
              let position = position(of: Int(descriptor.patchOffset), in: screen),
              position.row >= descriptor.viewportRow
        else { return false }
        return true
    }

    /// Whether the colours of what is already on screen still hold up to
    /// `limit`.
    ///
    /// A patch repaints from its offset onward, so it is only correct while
    /// everything before that offset still looks the way it was drawn. It
    /// often does not: a name becomes a verb on the keystroke that finishes
    /// it, and the bytes that changed meaning are the ones already painted.
    private static func stylesMatch(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        before limit: Int
    ) -> Bool {
        var painted = 0
        var framed  = 0
        let paintedCount = screen.styleSpanCount
        let framedCount  = Int(frame.descriptor.styleSpanCount)
        while true {
            let left  = painted < paintedCount ? screen.styleSpan(at: painted) : nil
            let right = framed < framedCount ? frame.styleSpan(at: framed) : nil
            let leftInside  = left.map { Int($0.offset) < limit } ?? false
            let rightInside = right.map { Int($0.offset) < limit } ?? false
            if !leftInside, !rightInside { return true }
            guard leftInside, rightInside, let left, let right else { return false }
            guard left.offset == right.offset,
                  left.role == right.role,
                  min(Int(left.offset) + Int(left.length), limit)
                      == min(Int(right.offset) + Int(right.length), limit)
            else { return false }
            painted += 1
            framed += 1
        }
    }

    private static func stylesMatch(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Bool {
        guard screen.styleSpanCount == Int(frame.descriptor.styleSpanCount) else { return false }
        for index in 0..<screen.styleSpanCount where screen.styleSpan(at: index) != frame.styleSpan(at: index) {
            return false
        }
        return true
    }

    private static func position(
        of offset: Int,
        in model: TextSurfaceScreenModel
    ) -> (row: UInt16, column: UInt16)? {
        guard let result = ReixTextLayout.position(
            at: offset,
            count: model.textLength,
            columns: model.columns,
            byte: model.textByte
        ) else { return nil }
        return (result.row, result.column)
    }

    private static func codePosition(
        of offset: Int,
        in model : TextSurfaceScreenModel
    ) -> (row: UInt16, column: UInt16)? {
        guard let result = ReixCodeEditorLayout.position(
            at: offset,
            count: model.textLength,
            columns: model.columns,
            byte: model.textByte
        ) else { return nil }
        return (result.row, result.column)
    }

    private static func desiredPosition(
        at offset: Int,
        screen   : TextSurfaceScreenModel,
        frame    : ReixTextSurfaceFrameView
    ) -> (row: UInt16, column: UInt16)? {
        guard let result = ReixTextLayout.position(
            at: offset,
            count: screen.desiredTextLength(for: frame),
            columns: frame.descriptor.columns,
            byte: { screen.desiredTextByte(at: $0, for: frame) }
        ) else { return nil }
        return (result.row, result.column)
    }

    private static func codeDesiredPosition(
        at offset: Int,
        screen   : TextSurfaceScreenModel,
        frame    : ReixTextSurfaceFrameView
    ) -> (row: UInt16, column: UInt16)? {
        guard let result = ReixCodeEditorLayout.position(
            at: offset,
            count: screen.desiredTextLength(for: frame),
            columns: frame.descriptor.columns,
            byte: { screen.desiredTextByte(at: $0, for: frame) }
        ) else { return nil }
        return (result.row, result.column)
    }

    private static func clearViewport(
        baseRow: UInt16,
        rows: UInt16,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        for row in 0..<rows {
            cup(row: baseRow + row, column: 1, count: &count, emit: emit)
            clearLine(count: &count, emit: emit)
        }
    }

    /// Sends the cursor to the last row without needing to know which one that is:
    /// CUP clamps, so an out-of-range row is the portable way to say "the bottom".
    /// Nothing is erased, because the transcript above belongs to the terminal.
    private static func parkAtBottom(
        count: inout UInt32,
        emit : (UInt8) -> Void
    ) {
        style(.plain, count: &count, emit: emit)
        cup(row: bottomRow, column: 1, count: &count, emit: emit)
    }

    private static func clearToViewportEnd(
        from row: UInt16,
        rows: UInt16,
        baseRow: UInt16,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        clearToLineEnd(count: &count, emit: emit)
        guard row + 1 < rows else { return }
        for next in (row + 1)..<rows {
            cup(row: baseRow + next, column: 1, count: &count, emit: emit)
            clearLine(count: &count, emit: emit)
        }
    }

    /// Writes the visible rows of the block, and only those. Every line break it
    /// emits has to land inside the block: one past the last row would scroll the
    /// screen out from under the anchor, and one before the first would waste it.
    private static func renderText(
        screen    : TextSurfaceScreenModel,
        frame     : ReixTextSurfaceFrameView,
        from start: Int,
        startRow  : UInt16,
        count     : inout UInt32,
        emit      : (UInt8) -> Void
    ) {
        let descriptor = frame.descriptor
        var row        : UInt16          = 0
        var column     : UInt16          = 0
        var activeRole = ReixTextSurfaceStyleRole.plain
        let length     = screen.desiredTextLength(for: frame)
        let byte       : (Int) -> UInt8? = { screen.desiredTextByte(at: $0, for: frame) }
        var offset     = 0
        while offset < length {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: length,
                byte: byte
            ),
                  let first = byte(offset),
                  let width = ReixTextLayout.cellWidth(
                      from: offset,
                      to: end,
                      count: length,
                      byte: byte
                  ),
                  width <= descriptor.columns
            else { return }
            let wrapsBefore = first != lineFeed
                && column > 0
                && width > descriptor.columns - column
            if wrapsBefore {
                row &+= 1
                column = 0
                // The cursor was placed on startRow, so that row needs no break.
                if offset >= start, row > startRow, visible(row, descriptor: descriptor) {
                    emitted(carriageReturn, count: &count, emit: emit)
                    emitted(lineFeed, count: &count, emit: emit)
                }
            }
            if offset >= start && visible(row, descriptor: descriptor) {
                let role = styleRole(at: offset, frame: frame)
                if role != activeRole {
                    style(role, count: &count, emit: emit)
                    activeRole = role
                }
                if first == lineFeed {
                    if visible(row &+ 1, descriptor: descriptor) {
                        emitted(carriageReturn, count: &count, emit: emit)
                        emitted(lineFeed, count: &count, emit: emit)
                    }
                } else {
                    emitGrapheme(byte: byte, from: offset, to: end, count: &count, emit: emit)
                }
            }
            if first == lineFeed {
                row &+= 1
                column = 0
            } else {
                column += width
                if column == descriptor.columns {
                    row &+= 1
                    column = 0
                }
            }
            offset = end
        }
        if activeRole != .plain { style(.plain, count: &count, emit: emit) }
    }

    /// Appended transcript text needs no layout of its own: the terminal wraps it.
    private static func renderChunk(
        frame: ReixTextSurfaceFrameView,
        count: inout UInt32,
        emit : (UInt8) -> Void
    ) {
        let length      = Int(frame.descriptor.textLength)
        let byte        : (Int) -> UInt8?          = { frame.textByte(at: $0) }
        let defaultRole : ReixTextSurfaceStyleRole = frame.descriptor.severity.rawValue
            >= ReixTextOutputSeverity.warning.rawValue
            || frame.descriptor.outputKind == .diagnostic
            || frame.descriptor.outputKind == .audit
            ? .diagnostic
            : .plain
        let background        = frame.descriptor.outputKind == .diagnostic
        var activeRole        = ReixTextSurfaceStyleRole.plain
        var offset            = 0
        var endedWithLineFeed = false
        while offset < length {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: length,
                byte: byte
            ), let first = byte(offset)
            else { return }
            let framedRole = styleRole(at: offset, frame: frame)
            let role       = framedRole == .plain ? defaultRole : framedRole
            if role != activeRole {
                style(role, background: background, count: &count, emit: emit)
                activeRole = role
            }
            if first == lineFeed {
                if background { clearToLineEnd(count: &count, emit: emit) }
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
                endedWithLineFeed = true
            } else {
                emitGrapheme(byte: byte, from: offset, to: end, count: &count, emit: emit)
                endedWithLineFeed = false
            }
            offset = end
        }
        if background && !endedWithLineFeed { clearToLineEnd(count: &count, emit: emit) }
        if activeRole != .plain || background { style(.plain, count: &count, emit: emit) }
    }

    private static func renderExternalPayload(
        _ record: ReixTextOutputRecord,
        count   : inout UInt32,
        emit    : (UInt8) -> Void
    ) {
        let role: ReixTextSurfaceStyleRole = record.severity.rawValue >= ReixTextOutputSeverity.warning.rawValue
            || record.kind == .diagnostic
            || record.kind == .audit
            ? .diagnostic
            : .plain
        let background = record.kind == .diagnostic
        if role != .plain || background {
            style(role, background: background, count: &count, emit: emit)
        }
        var offset            = 0
        var endedWithLineFeed = false
        while offset < record.payloadCount {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: record.payloadCount,
                byte: record.payloadByte
            ), let first = record.payloadByte(at: offset)
            else { return }
            if first == lineFeed {
                if background { clearToLineEnd(count: &count, emit: emit) }
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
                endedWithLineFeed = true
            } else {
                emitGrapheme(
                    byte: record.payloadByte,
                    from: offset,
                    to: end,
                    count: &count,
                    emit: emit
                )
                endedWithLineFeed = false
            }
            offset = end
        }
        if background && !endedWithLineFeed { clearToLineEnd(count: &count, emit: emit) }
        if role != .plain || background { style(.plain, count: &count, emit: emit) }
    }

    private static func renderStoredText(
        screen: TextSurfaceScreenModel,
        count : inout UInt32,
        emit  : (UInt8) -> Void
    ) {
        var row        : UInt16 = 0
        var column     : UInt16 = 0
        var activeRole = ReixTextSurfaceStyleRole.plain
        var offset     = 0

        while offset < screen.textLength {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: screen.textLength,
                byte: screen.textByte
            ),
                  let first = screen.textByte(at: offset),
                  let width = ReixTextLayout.cellWidth(
                    from: offset,
                    to: end,
                    count: screen.textLength,
                    byte: screen.textByte
                  ),
                  width <= screen.columns
            else { return }
            let wrapsBefore = first != lineFeed
                && column > 0
                && width > screen.columns - column
            if wrapsBefore {
                row &+= 1
                column = 0
                if row > screen.viewportRow && storedVisible(row, screen: screen) {
                    emitted(carriageReturn, count: &count, emit: emit)
                    emitted(lineFeed, count: &count, emit: emit)
                }
            }
            if storedVisible(row, screen: screen) {
                let role = storedStyleRole(at: offset, screen: screen)
                if role != activeRole {
                    style(role, count: &count, emit: emit)
                    activeRole = role
                }
                if first == lineFeed {
                    if storedVisible(row &+ 1, screen: screen) {
                        emitted(carriageReturn, count: &count, emit: emit)
                        emitted(lineFeed, count: &count, emit: emit)
                    }
                } else {
                    emitGrapheme(
                        byte: screen.textByte,
                        from: offset,
                        to: end,
                        count: &count,
                        emit: emit
                    )
                }
            }
            if first == lineFeed {
                row &+= 1
                column = 0
            } else {
                column += width
                if column == screen.columns {
                    row &+= 1
                    column = 0
                }
            }
            offset = end
        }
        if activeRole != .plain { style(.plain, count: &count, emit: emit) }
    }

    private static func renderStoredCodeEditor(
        screen : TextSurfaceScreenModel,
        baseRow: UInt16,
        count  : inout UInt32,
        emit   : (UInt8) -> Void
    ) {
        renderCodeEditorRows(
            length: screen.textLength,
            columns: screen.columns,
            viewportRow: screen.viewportRow,
            viewportRows: screen.viewportRows,
            baseRow: baseRow,
            startRow: screen.viewportRow,
            clearRepaintedRows: false,
            byte: screen.textByte,
            role: { storedStyleRole(at: $0, screen: screen) },
            count: &count,
            emit: emit
        )
        renderCodeEditorFooter(
            columns: screen.columns,
            viewportRows: screen.viewportRows,
            baseRow: baseRow,
            count: &count,
            emit: emit
        )
    }

    private static func renderCodeEditorRows(
        length            : Int,
        columns           : UInt16,
        viewportRow       : UInt16,
        viewportRows      : UInt16,
        baseRow           : UInt16,
        startRow          : UInt16,
        clearRepaintedRows: Bool,
        byte              : (Int) -> UInt8?,
        role              : (Int) -> ReixTextSurfaceStyleRole,
        count             : inout UInt32,
        emit              : (UInt8) -> Void
    ) {
        let contentRows     = ReixCodeEditorLayout.contentViewportRows(for: viewportRows)
        let firstContentRow = ReixCodeEditorLayout.firstVisibleContentRow(
            viewportRow: viewportRow
        )
        func isVisible(_ row: UInt16) -> Bool {
            row >= firstContentRow && row < firstContentRow + contentRows
        }

        if startRow == viewportRow {
            cup(row: baseRow, column: 1, count: &count, emit: emit)
            emitEditorHeader(columns: columns, background: false, count: &count, emit: emit)
        }

        let gutter         = ReixCodeEditorLayout.gutterColumns(for: columns)
        let contentColumns = columns - gutter
        guard contentColumns > 0 else { return }
        var offset       = 0
        var row          = ReixCodeEditorLayout.headerRows
        var line         = 1
        var logicalStart = true
        var pendingEmpty = length == 0

        while offset < length || pendingEmpty {
            pendingEmpty = false
            let segmentStart    = offset
            var segmentEnd      = offset
            var used            : UInt16 = 0
            var consumedNewline = false
            var wrapped         = false

            while offset < length {
                guard let end = ReixTextLayout.nextGraphemeBoundary(
                    after: offset,
                    count: length,
                    byte: byte
                ),
                      let first = byte(offset)
                else { return }
                if first == lineFeed {
                    offset = end
                    consumedNewline = true
                    break
                }
                guard let width = ReixTextLayout.cellWidth(
                    from: offset,
                    to: end,
                    count: length,
                    byte: byte
                ),
                      width <= contentColumns
                else { return }
                if used > 0 && width > contentColumns - used {
                    wrapped = true
                    break
                }
                used += width
                offset = end
                segmentEnd = end
                if used == contentColumns {
                    wrapped = true
                    break
                }
            }

            if row >= startRow && isVisible(row) {
                cup(
                    row: baseRow + ReixCodeEditorLayout.headerRows + row - firstContentRow,
                    column: 1,
                    count: &count,
                    emit: emit
                )
                emitCodeGutter(
                    line: logicalStart ? line : nil,
                    columns: gutter,
                    background: false,
                    count: &count,
                    emit: emit
                )
                var activeRole = ReixTextSurfaceStyleRole.plain
                var current    = segmentStart
                while current < segmentEnd {
                    guard let end = ReixTextLayout.nextGraphemeBoundary(
                        after: current,
                        count: length,
                        byte: byte
                    ) else { return }
                    let nextRole = role(current)
                    if nextRole != activeRole {
                        style(nextRole, count: &count, emit: emit)
                        activeRole = nextRole
                    }
                    emitGrapheme(
                        byte: byte,
                        from: current,
                        to: end,
                        count: &count,
                        emit: emit
                    )
                    current = end
                }
                if activeRole != .plain { style(.plain, count: &count, emit: emit) }
                if clearRepaintedRows && used < contentColumns {
                    clearToLineEnd(count: &count, emit: emit)
                }
            }

            if consumedNewline {
                line += 1
                logicalStart = true
            } else if wrapped {
                logicalStart = false
            } else {
                break
            }
            if offset == length { pendingEmpty = true }
            guard row < UInt16.max else { return }
            row += 1
        }
    }

    private static func renderCodeEditorFooter(
        columns     : UInt16,
        viewportRows: UInt16,
        baseRow     : UInt16,
        count       : inout UInt32,
        emit        : (UInt8) -> Void
    ) {
        guard ReixCodeEditorLayout.footerRows(for: viewportRows) == 1 else { return }
        cup(
            row: baseRow + viewportRows - 1,
            column: 1,
            count: &count,
            emit: emit
        )
        style(.editorChrome, background: true, count: &count, emit: emit)
        let hint            = StaticString("Ctrl+Enter run  |  Enter newline  |  Tab indent")
        let writableColumns = columns > 0 ? Int(columns - 1) : 0
        let limit           = min(hint.utf8CodeUnitCount, writableColumns)
        for index in 0..<limit {
            emitted(hint.utf8Start[index], count: &count, emit: emit)
        }
        clearToLineEnd(count: &count, emit: emit)
        style(.plain, count: &count, emit: emit)
    }

    private static func emitEditorHeader(
        columns   : UInt16,
        background: Bool,
        count     : inout UInt32,
        emit      : (UInt8) -> Void
    ) {
        var remaining = Int(columns)
        style(.prompt, background: background, count: &count, emit: emit)
        let name      = StaticString("reix")
        let nameCount = min(name.utf8CodeUnitCount, remaining)
        for index in 0..<nameCount {
            emitted(name.utf8Start[index], count: &count, emit: emit)
        }
        remaining -= nameCount
        if nameCount == name.utf8CodeUnitCount, remaining > 0 {
            let mark = StaticString("❯")
            for index in 0..<mark.utf8CodeUnitCount {
                emitted(mark.utf8Start[index], count: &count, emit: emit)
            }
            remaining -= 1
        }
        if remaining > 0 {
            emitted(0x20, count: &count, emit: emit)
            remaining -= 1
        }
        style(.editorChrome, background: background, count: &count, emit: emit)
        let title      = StaticString("Editor Mode")
        let titleCount = min(title.utf8CodeUnitCount, remaining)
        for index in 0..<titleCount {
            emitted(title.utf8Start[index], count: &count, emit: emit)
        }
        style(.plain, background: background, count: &count, emit: emit)
    }

    private static func renderCodeTranscript(
        frame: ReixTextSurfaceFrameView,
        count: inout UInt32,
        emit : (UInt8) -> Void
    ) {
        let columns = frame.descriptor.columns
        emitEditorHeader(columns: columns, background: true, count: &count, emit: emit)
        clearToLineEnd(count: &count, emit: emit)
        style(.plain, count: &count, emit: emit)
        emitted(carriageReturn, count: &count, emit: emit)
        emitted(lineFeed, count: &count, emit: emit)

        let length         = Int(frame.descriptor.textLength)
        let byte           : (Int) -> UInt8? = { frame.textByte(at: $0) }
        let gutter         = ReixCodeEditorLayout.gutterColumns(for: columns)
        let contentColumns = columns - gutter
        guard contentColumns > 0 else { return }
        var offset       = 0
        var line         = 1
        var logicalStart = true
        var pendingEmpty = length == 0

        while offset < length || pendingEmpty {
            pendingEmpty = false
            let segmentStart    = offset
            var segmentEnd      = offset
            var used            : UInt16 = 0
            var consumedNewline = false
            var wrapped         = false

            while offset < length {
                guard let end = ReixTextLayout.nextGraphemeBoundary(
                    after: offset,
                    count: length,
                    byte: byte
                ),
                      let first = byte(offset)
                else { return }
                if first == lineFeed {
                    offset = end
                    consumedNewline = true
                    break
                }
                guard let width = ReixTextLayout.cellWidth(
                    from: offset,
                    to: end,
                    count: length,
                    byte: byte
                ),
                      width <= contentColumns
                else { return }
                if used > 0 && width > contentColumns - used {
                    wrapped = true
                    break
                }
                used += width
                offset = end
                segmentEnd = end
                if used == contentColumns {
                    wrapped = true
                    break
                }
            }

            emitCodeGutter(
                line: logicalStart ? line : nil,
                columns: gutter,
                background: true,
                count: &count,
                emit: emit
            )
            var activeRole = ReixTextSurfaceStyleRole.plain
            var current    = segmentStart
            while current < segmentEnd {
                guard let end = ReixTextLayout.nextGraphemeBoundary(
                    after: current,
                    count: length,
                    byte: byte
                ) else { return }
                let nextRole = styleRole(at: current, frame: frame)
                if nextRole != activeRole {
                    style(nextRole, background: true, count: &count, emit: emit)
                    activeRole = nextRole
                }
                emitGrapheme(
                    byte: byte,
                    from: current,
                    to: end,
                    count: &count,
                    emit: emit
                )
                current = end
            }
            style(.plain, background: true, count: &count, emit: emit)
            clearToLineEnd(count: &count, emit: emit)
            style(.plain, count: &count, emit: emit)
            emitted(carriageReturn, count: &count, emit: emit)
            emitted(lineFeed, count: &count, emit: emit)

            if consumedNewline {
                line += 1
                logicalStart = true
            } else if wrapped {
                logicalStart = false
            } else {
                break
            }
            if offset == length { pendingEmpty = true }
        }
    }

    private static func emitCodeGutter(
        line      : Int?,
        columns   : UInt16,
        background: Bool,
        count     : inout UInt32,
        emit      : (UInt8) -> Void
    ) {
        guard columns > 0 else { return }
        style(.editorChrome, background: background, count: &count, emit: emit)
        if columns == ReixCodeEditorLayout.standardGutterColumns {
            if let line {
                emitPaddedDecimal(line, width: 4, count: &count, emit: emit)
            } else {
                for _ in 0..<4 { emitted(0x20, count: &count, emit: emit) }
            }
            emitted(0x20, count: &count, emit: emit)
            emitted(UInt8(ascii: "|"), count: &count, emit: emit)
            emitted(0x20, count: &count, emit: emit)
        } else {
            emitted(UInt8((line ?? 0) % 10) + 0x30, count: &count, emit: emit)
            emitted(UInt8(ascii: "|"), count: &count, emit: emit)
            emitted(0x20, count: &count, emit: emit)
        }
        style(.plain, background: background, count: &count, emit: emit)
    }

    private static func emitPaddedDecimal(
        _ value: Int,
        width  : Int,
        count  : inout UInt32,
        emit   : (UInt8) -> Void
    ) {
        var divisor = 1
        var digits  = 1
        while value / divisor >= 10 {
            divisor *= 10
            digits += 1
        }
        while divisor > 0 {
            emitted(UInt8(value / divisor % 10) + 0x30, count: &count, emit: emit)
            divisor /= 10
        }
        for _ in digits..<width { emitted(0x20, count: &count, emit: emit) }
    }

    private static func renderStoredOverlay(
        screen : TextSurfaceScreenModel,
        baseRow: UInt16,
        count  : inout UInt32,
        emit   : (UInt8) -> Void
    ) {
        guard screen.overlayLength > 0 else { return }
        cup(
            row: baseRow + screen.overlayRow,
            column: screen.overlayColumn + 1,
            count: &count,
            emit: emit
        )
        var role   = ReixTextSurfaceStyleRole.plain
        var offset = 0
        while offset < screen.overlayLength {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: screen.overlayLength,
                byte: screen.overlayByte
            ), let first = screen.overlayByte(at: offset)
            else { return }
            let next = storedOverlayStyleRole(at: offset, screen: screen)
            if next != role { style(next, count: &count, emit: emit); role = next }
            if first == lineFeed {
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
            } else {
                emitGrapheme(
                    byte: screen.overlayByte,
                    from: offset,
                    to: end,
                    count: &count,
                    emit: emit
                )
            }
            offset = end
        }
        if role != .plain { style(.plain, count: &count, emit: emit) }
    }

    private static func storedVisible(
        _ row : UInt16,
        screen: TextSurfaceScreenModel
    ) -> Bool {
        row >= screen.viewportRow && row < screen.viewportRow + screen.viewportRows
    }

    private static func storedStyleRole(
        at offset: Int,
        screen   : TextSurfaceScreenModel
    ) -> ReixTextSurfaceStyleRole {
        for index in 0..<screen.styleSpanCount {
            guard let span = screen.styleSpan(at: index) else { return .plain }
            if offset >= Int(span.offset), offset < Int(span.offset) + Int(span.length) {
                return span.role
            }
        }
        return .plain
    }

    private static func storedOverlayStyleRole(
        at offset: Int,
        screen   : TextSurfaceScreenModel
    ) -> ReixTextSurfaceStyleRole {
        for index in 0..<screen.overlayStyleSpanCount {
            guard let span = screen.overlayStyleSpan(at: index) else { return .overlay }
            if offset >= Int(span.offset), offset < Int(span.offset) + Int(span.length) {
                return span.role
            }
        }
        return .overlay
    }

    private static func emitGrapheme(
        byte      : (Int) -> UInt8?,
        from start: Int,
        to end    : Int,
        count     : inout UInt32,
        emit      : (UInt8) -> Void
    ) {
        guard let first = byte(start) else { return }
        let second      = start + 1 < end ? byte(start + 1) : nil
        let isC1Control = if let second {
            first == 0xC2 && second >= 0x80 && second <= 0x9F
        } else {
            false
        }
        let control = first < 0x20 || first == 0x7F
            || isC1Control
        if control {
            emitted(0xEF, count: &count, emit: emit)
            emitted(0xBF, count: &count, emit: emit)
            emitted(0xBD, count: &count, emit: emit)
            return
        }
        for index in start..<end {
            guard let value = byte(index) else { return }
            emitted(value, count: &count, emit: emit)
        }
    }

    private static func visible(
        _ row: UInt16,
        descriptor: ReixTextSurfaceFrameDescriptor
    ) -> Bool {
        row >= descriptor.viewportRow && row < descriptor.viewportRow + descriptor.viewportRows
    }

    private static func renderOverlay(
        _ frame: ReixTextSurfaceFrameView,
        baseRow: UInt16,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        let descriptor = frame.descriptor
        guard descriptor.overlayLength > 0 else { return }
        cup(
            row: baseRow + descriptor.overlayRow,
            column: descriptor.overlayColumn + 1,
            count: &count,
            emit: emit
        )
        var role = ReixTextSurfaceStyleRole.plain
        for index in 0..<Int(descriptor.overlayLength) {
            let next = overlayStyleRole(at: index, frame: frame)
            if next != role { style(next, count: &count, emit: emit); role = next }
            guard let byte = frame.overlayByte(at: index) else { return }
            if byte == lineFeed {
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
            } else {
                emitted(byte, count: &count, emit: emit)
            }
        }
        if role != .plain { style(.plain, count: &count, emit: emit) }
    }

    private static func styleRole(
        at offset: Int,
        frame: ReixTextSurfaceFrameView
    ) -> ReixTextSurfaceStyleRole {
        for index in 0..<Int(frame.descriptor.styleSpanCount) {
            guard let span = frame.styleSpan(at: index) else { return .plain }
            if offset >= Int(span.offset), offset < Int(span.offset) + Int(span.length) { return span.role }
        }
        return .plain
    }

    private static func overlayStyleRole(
        at offset: Int,
        frame: ReixTextSurfaceFrameView
    ) -> ReixTextSurfaceStyleRole {
        for index in 0..<Int(frame.descriptor.overlayStyleSpanCount) {
            guard let span = frame.overlayStyleSpan(at: index) else { return .plain }
            if offset >= Int(span.offset), offset < Int(span.offset) + Int(span.length) { return span.role }
        }
        return .overlay
    }

    /// Paints one role, by asking the palette what it is worth in SGR.
    ///
    /// The renderer knows escapes and the palette knows colours; nothing here
    /// knows what a `command` is, which is the whole point of the roles.
    private static func style(
        _ role    : ReixTextSurfaceStyleRole,
        background: Bool = false,
        count     : inout UInt32,
        emit      : (UInt8) -> Void
    ) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        // Always reset first. Roles are additive, so anything else leaves the
        // previous role's attributes running underneath this one, which is how
        // a selected row's reverse video reached the rows below it.
        emitted(UInt8(ascii: "0"), count: &count, emit: emit)
        if background {
            let code = StaticString(";48;5;236")
            for index in 0..<code.utf8CodeUnitCount {
                emitted(code.utf8Start[index], count: &count, emit: emit)
            }
        }
        let parameters = TextSurfacePalette.parameters(for: role)
        if parameters.utf8CodeUnitCount > 0 {
            emitted(UInt8(ascii: ";"), count: &count, emit: emit)
            for index in 0..<parameters.utf8CodeUnitCount {
                emitted(parameters.utf8Start[index], count: &count, emit: emit)
            }
        }
        emitted(UInt8(ascii: "m"), count: &count, emit: emit)
    }

    private static func cup(
        row: UInt16,
        column: UInt16,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        decimal(row, count: &count, emit: emit)
        emitted(UInt8(ascii: ";"), count: &count, emit: emit)
        decimal(column, count: &count, emit: emit)
        emitted(UInt8(ascii: "H"), count: &count, emit: emit)
    }

    private static func cursorVisible(
        _ visible: Bool,
        count    : inout UInt32,
        emit     : (UInt8) -> Void
    ) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        emitted(UInt8(ascii: "?"), count: &count, emit: emit)
        emitted(UInt8(ascii: "2"), count: &count, emit: emit)
        emitted(UInt8(ascii: "5"), count: &count, emit: emit)
        emitted(UInt8(ascii: visible ? "h" : "l"), count: &count, emit: emit)
    }

    private static func decimal(
        _ value: UInt16,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        var divisor: UInt16 = 1
        while value / divisor >= 10 { divisor *= 10 }
        while divisor > 0 {
            emitted(UInt8(value / divisor % 10) + 0x30, count: &count, emit: emit)
            divisor /= 10
        }
    }

    private static func clearToLineEnd(count: inout UInt32, emit: (UInt8) -> Void) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        emitted(UInt8(ascii: "K"), count: &count, emit: emit)
    }

    private static func clearLine(count: inout UInt32, emit: (UInt8) -> Void) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        emitted(UInt8(ascii: "2"), count: &count, emit: emit)
        emitted(UInt8(ascii: "K"), count: &count, emit: emit)
    }

    private static func emitted(
        _ byte: UInt8,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        emit(byte)
        if count < UInt32.max { count += 1 }
    }

    /// Larger than any terminal this surface addresses, so CUP clamps to the last row.
    private static let bottomRow: UInt16 = 999

    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let escape: UInt8 = 0x1B
    private static let openBracket: UInt8 = 0x5B
}
