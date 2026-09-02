//
//  TextSurfaceVTRenderer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

/// Deterministic local conversion from semantic screen frames to bounded VT output.
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

    private static func renderPlan(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        switch frame.descriptor.mode {
            case .transcript:
                return renderTranscriptPlan(
                    screen: screen,
                    frame: frame,
                    useDiff: useDiff,
                    emit: emit
                )
            case .editor:
                return renderEditorPlan(
                    screen: screen,
                    frame: frame,
                    useDiff: useDiff,
                    emit: emit
                )
        }
    }

    private static func renderEditorPlan(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        var count: UInt32 = 0
        let descriptor = frame.descriptor
        let baseRow = descriptor.rows - descriptor.viewportRows + 1
        let start = useDiff ? Int(descriptor.patchOffset) : 0
        var startRow = descriptor.viewportRow
        var startColumn: UInt16 = 0

        if useDiff,
           descriptor.textLength == 0,
           descriptor.replacedLength == 0,
           stylesMatch(screen: screen, frame: frame) {
            style(.plain, count: &count, emit: emit)
            cup(
                row: baseRow + descriptor.cursorRow - descriptor.viewportRow,
                column: descriptor.cursorColumn + 1,
                count: &count,
                emit: emit
            )
            return count
        }

        if useDiff, let position = position(of: start, in: screen),
           position.row >= descriptor.viewportRow,
           position.row < descriptor.viewportRow + descriptor.viewportRows {
            startRow = position.row
            startColumn = position.column
            if descriptor.patchOffset != UInt32(screen.textLength)
                || descriptor.replacedLength != 0 {
                cup(
                    row: baseRow + position.row - descriptor.viewportRow,
                    column: position.column + 1,
                    count: &count,
                    emit: emit
                )
                clearToViewportEnd(
                    from: position.row - descriptor.viewportRow,
                    rows: descriptor.viewportRows,
                    baseRow: baseRow,
                    count: &count,
                    emit: emit
                )
            }
        } else {
            let clearBase = editorClearBase(screen: screen, descriptor: descriptor)
            clearViewport(
                baseRow: clearBase,
                rows: descriptor.rows - clearBase + 1,
                count: &count,
                emit: emit
            )
        }
        cup(
            row: baseRow + startRow - descriptor.viewportRow,
            column: startColumn + 1,
            count: &count,
            emit: emit
        )
        renderText(screen: screen, frame: frame, from: start, count: &count, emit: emit)
        renderOverlay(frame, baseRow: baseRow, count: &count, emit: emit)
        style(.plain, count: &count, emit: emit)
        cup(
            row: baseRow + descriptor.cursorRow - descriptor.viewportRow,
            column: descriptor.cursorColumn + 1,
            count: &count,
            emit: emit
        )
        return count
    }

    private static func renderTranscriptPlan(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        useDiff: Bool,
        emit: (UInt8) -> Void
    ) -> UInt32 {
        var count: UInt32 = 0
        let start: Int
        if useDiff {
            start = Int(frame.descriptor.patchOffset)
        } else {
            start = 0
            if screen.revision != 0 {
                clearDisplay(count: &count, emit: emit)
            }
        }
        renderTranscriptText(
            screen: screen,
            frame: frame,
            from: start,
            count: &count,
            emit: emit
        )
        style(.plain, count: &count, emit: emit)
        return count
    }

    private static func diffEligible(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Bool {
        switch frame.descriptor.mode {
            case .transcript:
                return transcriptDiffEligible(screen: screen, frame: frame)
            case .editor:
                return editorDiffEligible(screen: screen, frame: frame)
        }
    }

    private static func editorDiffEligible(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Bool {
        let descriptor = frame.descriptor
        guard descriptor.kind == .patch,
              screen.mode == .editor,
              descriptor.overlayLength == 0,
              screen.overlayLength == 0,
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

    private static func transcriptDiffEligible(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView
    ) -> Bool {
        let descriptor = frame.descriptor
        guard descriptor.kind == .patch,
              descriptor.columns == screen.columns,
              descriptor.rows == screen.rows,
              descriptor.overlayLength == 0,
              screen.overlayLength == 0,
              descriptor.patchOffset == UInt32(screen.textLength),
              descriptor.replacedLength == 0,
              ReixTextLayout.isGraphemeBoundary(
                  Int(descriptor.patchOffset),
                  count: screen.desiredTextLength(for: frame),
                  byte: { screen.desiredTextByte(at: $0, for: frame) }
              )
        else { return false }
        return true
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

    private static func editorClearBase(
        screen: TextSurfaceScreenModel,
        descriptor: ReixTextSurfaceFrameDescriptor
    ) -> UInt16 {
        guard screen.mode == .editor,
              screen.rows == descriptor.rows,
              screen.viewportRows <= screen.rows
        else { return descriptor.rows - descriptor.viewportRows + 1 }
        let oldBase = screen.rows - screen.viewportRows + 1
        let newBase = descriptor.rows - descriptor.viewportRows + 1
        return min(oldBase, newBase)
    }

    private static func clearDisplay(
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        emitted(UInt8(ascii: "2"), count: &count, emit: emit)
        emitted(UInt8(ascii: "J"), count: &count, emit: emit)
        cup(row: 1, column: 1, count: &count, emit: emit)
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

    private static func renderText(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        from start: Int,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        let descriptor = frame.descriptor
        var row: UInt16 = 0
        var column: UInt16 = 0
        var activeRole = ReixTextSurfaceStyleRole.plain
        let length = screen.desiredTextLength(for: frame)
        var offset = 0
        while offset < length {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: length,
                byte: { screen.desiredTextByte(at: $0, for: frame) }
            ),
                  let first = screen.desiredTextByte(at: offset, for: frame),
                  let width = ReixTextLayout.cellWidth(
                      from: offset,
                      to: end,
                      count: length,
                      byte: { screen.desiredTextByte(at: $0, for: frame) }
                  )
            else { return }
            let wrapsBefore = first != lineFeed
                && column > 0
                && width > descriptor.columns - column
            if wrapsBefore {
                row &+= 1
                column = 0
                if offset >= start && visible(row, descriptor: descriptor) {
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
                    emitted(carriageReturn, count: &count, emit: emit)
                    emitted(lineFeed, count: &count, emit: emit)
                } else {
                    emitGrapheme(
                        screen: screen,
                        frame: frame,
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
                if column == descriptor.columns {
                    row &+= 1
                    column = 0
                }
            }
            offset = end
        }
        if activeRole != .plain { style(.plain, count: &count, emit: emit) }
    }

    private static func renderTranscriptText(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        from start: Int,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        let length = screen.desiredTextLength(for: frame)
        var activeRole = ReixTextSurfaceStyleRole.plain
        var offset = start
        while offset < length {
            guard let end = ReixTextLayout.nextGraphemeBoundary(
                after: offset,
                count: length,
                byte: { screen.desiredTextByte(at: $0, for: frame) }
            ), let first = screen.desiredTextByte(at: offset, for: frame)
            else { return }
            let role = styleRole(at: offset, frame: frame)
            if role != activeRole {
                style(role, count: &count, emit: emit)
                activeRole = role
            }
            if first == lineFeed {
                emitted(carriageReturn, count: &count, emit: emit)
                emitted(lineFeed, count: &count, emit: emit)
            } else {
                emitGrapheme(
                    screen: screen,
                    frame: frame,
                    from: offset,
                    to: end,
                    count: &count,
                    emit: emit
                )
            }
            offset = end
        }
        if activeRole != .plain { style(.plain, count: &count, emit: emit) }
    }

    private static func emitGrapheme(
        screen: TextSurfaceScreenModel,
        frame: ReixTextSurfaceFrameView,
        from start: Int,
        to end: Int,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        guard let first = screen.desiredTextByte(at: start, for: frame) else { return }
        let second = start + 1 < end ? screen.desiredTextByte(at: start + 1, for: frame) : nil
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
            guard let byte = screen.desiredTextByte(at: index, for: frame) else { return }
            emitted(byte, count: &count, emit: emit)
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

    private static func style(
        _ role: ReixTextSurfaceStyleRole,
        count: inout UInt32,
        emit: (UInt8) -> Void
    ) {
        emitted(escape, count: &count, emit: emit)
        emitted(openBracket, count: &count, emit: emit)
        switch role {
            case .plain, .input:
                emitted(UInt8(ascii: "0"), count: &count, emit: emit)
            case .prompt:
                emitted(UInt8(ascii: "1"), count: &count, emit: emit)
                emitted(UInt8(ascii: ";"), count: &count, emit: emit)
                emitted(UInt8(ascii: "3"), count: &count, emit: emit)
                emitted(UInt8(ascii: "6"), count: &count, emit: emit)
            case .selection:
                emitted(UInt8(ascii: "7"), count: &count, emit: emit)
            case .diagnostic:
                emitted(UInt8(ascii: "3"), count: &count, emit: emit)
                emitted(UInt8(ascii: "1"), count: &count, emit: emit)
            case .overlay:
                emitted(UInt8(ascii: "3"), count: &count, emit: emit)
                emitted(UInt8(ascii: "5"), count: &count, emit: emit)
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

    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let escape: UInt8 = 0x1B
    private static let openBracket: UInt8 = 0x5B
}
