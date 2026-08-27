//
//  ShellLineEditor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

/// The shell-owned, bounded multiline editor.
///
/// Terminal IPC carries semantic keys, not escape bytes or a completed command.
/// This value owns cursor movement, UTF-8 boundaries, parser completeness and
/// history. A submitted line is copied out by the shell before the next event.
public struct ShellLineEditor {
    /// Leaves room for the prompt in an atomic replace-line patch.
    public static let capacity        = 250
    public static let historyCapacity = 8

    private struct HistoryEntry {
        var bytes = InlineArray<256, UInt8>(repeating: 0)
        var count = 0
    }

    private var bytes = InlineArray<256, UInt8>(repeating: 0)
    public private(set) var count = 0
    public private(set) var cursor = 0
    private var history           = InlineArray<8, HistoryEntry?>(repeating: nil)
    private var historyCount      = 0
    private var historyIndex      = 0
    private var patchSequence     : UInt32 = 0
    private var renderedRows      = 1
    private var renderedCursorRow = 0

    public init() {}

    public mutating func apply(_ event: TerminalInputEvent) -> ShellEditorUpdate {
        patchSequence &+= 1
        if patchSequence == 0 { patchSequence = 1 }
        let previousCursor = cursor
        let previousCount  = count
        switch event.kind {
            case .insert:
                guard event.count > 0, event.count <= Self.capacity - count else { return refused() }
                var index = count
                while index > cursor {
                    index -= 1
                    bytes[index + event.count] = bytes[index]
                }
                for offset in 0..<event.count { bytes[cursor + offset] = event.text[offset] }
                cursor += event.count
                count += event.count
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .left:
                guard cursor > 0 else { return refused() }
                let previous = previousBoundary(before: cursor)
                cursor = previous
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .right:
                guard cursor < count else { return refused() }
                let next = nextBoundary(after: cursor)
                cursor = next
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .home:
                guard cursor > 0 else { return refused() }
                let start = rowStart(containing: cursor)
                guard cursor != start else { return refused() }
                cursor = start
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .end:
                let end = rowEnd(containing: cursor)
                guard cursor != end else { return refused() }
                cursor = end
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .backspace:
                guard cursor > 0 else { return refused() }
                let start   = previousBoundary(before: cursor)
                let removed = cursor - start
                remove(at: start, count: removed)
                cursor = start
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .delete:
                guard cursor < count else { return refused() }
                let end = nextBoundary(after: cursor)
                remove(at: cursor, count: end - cursor)
                return replaced(previousCursor: previousCursor, previousCount: previousCount)

            case .up:
                if moveVertically(up: true) {
                    return replaced(previousCursor: previousCursor, previousCount: previousCount)
                }
                return historyStep(previous: true, previousCursor: previousCursor, previousCount: previousCount)

            case .down:
                if moveVertically(up: false) {
                    return replaced(previousCursor: previousCursor, previousCount: previousCount)
                }
                return historyStep(previous: false, previousCursor: previousCursor, previousCount: previousCount)

            case .historyPrevious:
                return historyStep(previous: true, previousCursor: previousCursor, previousCount: previousCount)

            case .historyNext:
                return historyStep(previous: false, previousCursor: previousCursor, previousCount: previousCount)

            case .enter:
                let completeness = bytes.span.withUnsafeBufferPointer {
                    TypedShellParser.completeness($0.baseAddress!, count: count)
                }
                if case .incomplete(let indent) = completeness {
                    let added = 1 + min(indent * 4, 16)
                    guard added <= Self.capacity - count else { return refused() }
                    var index = count
                    while index > cursor { index -= 1; bytes[index + added] = bytes[index] }
                    bytes[cursor] = 0x0A
                    if added > 1 { for offset in 1..<added { bytes[cursor + offset] = 0x20 } }
                    cursor += added
                    count += added
                    return replaced(previousCursor: previousCursor, previousCount: previousCount)
                }
                guard completeness == .complete else { return refused() }
                remember()
                return ShellEditorUpdate(action: .submitted(count), patch: TerminalRenderPatch(kind: .newline, sequence: patchSequence))

            case .cancel:
                clear()
                return ShellEditorUpdate(action: .cancelled, patch: TerminalRenderPatch(kind: .newline, sequence: patchSequence))

            case .eof:
                guard count == 0 else { return refused() }
                return ShellEditorUpdate(action: .eof, patch: TerminalRenderPatch(kind: .newline, sequence: patchSequence))

            case .resize:
                return ShellEditorUpdate(action: .resized(event.width, event.height), patch: nil)

            case .ignored:
                return refused()
        }
    }

    public func copyLine(into destination: inout InlineArray<256, UInt8>) -> Int {
        for index in 0..<count { destination[index] = bytes[index] }
        return count
    }

    public mutating func reset() { clear() }

    private mutating func remove(
          at start    : Int,
          count amount: Int
    ) {
        var index = start
        while index + amount < count {
            bytes[index] = bytes[index + amount]
            index += 1
        }
        count -= amount
    }

    private func previousBoundary(before position: Int) -> Int {
        var index = position - 1
        while index > 0, bytes[index] & 0xC0 == 0x80 { index -= 1 }
        return index
    }

    private func nextBoundary(after position: Int) -> Int {
        var index = position + 1
        while index < count, bytes[index] & 0xC0 == 0x80 { index += 1 }
        return index
    }

    private mutating func remember() {
        guard count > 0 else { return }
        var entry = HistoryEntry()
        entry.count = count
        for index in 0..<count { entry.bytes[index] = bytes[index] }
        if historyCount < history.count {
            history[historyCount] = entry
            historyCount += 1
        } else {
            for index in 1..<history.count { history[index - 1] = history[index] }
            history[history.count - 1] = entry
        }
        historyIndex = historyCount
    }

    private mutating func historyStep(
          previous      : Bool,
          previousCursor: Int,
          previousCount : Int
    ) -> ShellEditorUpdate {
        guard historyCount > 0 else { return refused() }
        if previous {
            guard historyIndex > 0 else { return refused() }
            historyIndex -= 1
        } else {
            guard historyIndex + 1 < historyCount else {
                historyIndex = historyCount
                clear(keepHistoryIndex: true, keepRendering: true)
                return replaced(previousCursor: previousCursor, previousCount: previousCount)
            }
            historyIndex += 1
        }
        guard let entry = history[historyIndex] else { return refused() }
        count = entry.count
        cursor = count
        for index in 0..<count { bytes[index] = entry.bytes[index] }
        return replaced(previousCursor: previousCursor, previousCount: previousCount)
    }

    private mutating func clear(
          keepHistoryIndex: Bool = false,
          keepRendering   : Bool = false
    ) {
        count = 0
        cursor = 0
        if !keepRendering {
            renderedRows = 1
            renderedCursorRow = 0
        }
        if !keepHistoryIndex { historyIndex = historyCount }
    }

    private mutating func replaced(
          previousCursor _: Int,
          previousCount _ : Int
    ) -> ShellEditorUpdate {
        var row    = InlineArray<256, UInt8>(repeating: 0)
        let prompt : StaticString = "reix> "
        for index in 0..<prompt.utf8CodeUnitCount { row[index] = prompt.utf8Start[index] }
        for index in 0..<count { row[prompt.utf8CodeUnitCount + index] = bytes[index] }
        let rowCount      = prompt.utf8CodeUnitCount + count
        let newRow        = rowIndex(at: cursor, count: count)
        let logicalColumn = characterColumn(at: cursor)
        let oldRow        = renderedCursorRow
        let oldRows       = renderedRows
        let update        = row.span.withUnsafeBufferPointer {
            ShellEditorUpdate(
                action: .editing,
                patch: TerminalRenderPatch(
                    kind: .replaceBuffer,
                    sequence: patchSequence,
                    bytes: $0.baseAddress!,
                    count: rowCount,
                    previousRows: UInt16(oldRows),
                    previousCursorRow: UInt16(oldRow),
                    cursorRow: UInt16(newRow),
                    cursorColumn: UInt16(logicalColumn + (newRow == 0 ? prompt.utf8CodeUnitCount : 0))
                )
            )
        }
        renderedRows = rowIndex(at: count, count: count) + 1
        renderedCursorRow = newRow
        return update
    }

    private func refused() -> ShellEditorUpdate {
        ShellEditorUpdate(action: .refused, patch: TerminalRenderPatch(kind: .bell, sequence: patchSequence))
    }

    private func rowStart(containing position: Int) -> Int {
        var index = min(position, count)
        while index > 0, bytes[index - 1] != 0x0A { index -= 1 }
        return index
    }

    private func rowEnd(containing position: Int) -> Int {
        var index = min(position, count)
        while index < count, bytes[index] != 0x0A { index += 1 }
        return index
    }

    private func rowIndex(
          at position: Int,
          count limit: Int
    ) -> Int {
        var rows = 0
        for index in 0..<min(position, limit) where bytes[index] == 0x0A { rows += 1 }
        return rows
    }

    private func characterColumn(at position: Int) -> Int {
        let start  = rowStart(containing: position)
        var column = 0
        if start < position {
            for index in start..<position where bytes[index] & 0xC0 != 0x80 { column += 1 }
        }
        return column
    }

    private mutating func moveVertically(up: Bool) -> Bool {
        let start       = rowStart(containing: cursor)
        let column      = characterColumn(at: cursor)
        let targetStart : Int
        let targetEnd   : Int
        if up {
            guard start > 0 else { return false }
            targetEnd = start - 1
            targetStart = rowStart(containing: targetEnd)
        } else {
            let end = rowEnd(containing: cursor)
            guard end < count else { return false }
            targetStart = end + 1
            targetEnd = rowEnd(containing: targetStart)
        }
        var position  = targetStart
        var remaining = column
        while position < targetEnd, remaining > 0 {
            position = nextBoundary(after: position)
            remaining -= 1
        }
        cursor = position
        return true
    }
}
