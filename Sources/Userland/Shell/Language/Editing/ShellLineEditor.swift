//
//  ShellLineEditor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

/// A bounded multiline editor whose gap is always the insertion point.
public struct ShellLineEditor: ~Copyable {
    public static let prompt: StaticString = "reix❯ "
    public static let promptBytes = 8
    public static let promptColumns = 6
    public static let inlineCapacity = 384
    public static let capacity = 8192
    public static let historyByteBudget = 4096
    public static let undoByteBudget = 2048
    public static let historyCapacity = 32
    public static let undoCapacity = 32

    private struct EditRecord {
        var offset = 0
        var removedOffset = 0
        var removedCount = 0
        var insertedOffset = 0
        var insertedCount = 0

        var payloadEnd: Int { insertedOffset + insertedCount }
        var payloadCount: Int { removedCount + insertedCount }
    }

    private struct HistoryRecord {
        var offset = 0
        var count = 0
    }

    private enum PendingChange {
        case snapshot
        case patch(offset: Int, removed: Int, inserted: Int)
        case metadata
    }

    private var inline = InlineArray<384, UInt8>(repeating: 0)
    private var heap: UnsafeMutablePointer<UInt8>?
    private var storageCapacity = Self.inlineCapacity
    private var gapStart = 0
    private var gapEnd = Self.inlineCapacity

    private var edits = InlineArray<32, EditRecord?>(repeating: nil)
    private var editCount = 0
    private var appliedEdits = 0
    private var editBytes: UnsafeMutablePointer<UInt8>?
    private var editByteCount = 0

    private var history = InlineArray<32, HistoryRecord?>(repeating: nil)
    private var historyCount = 0
    private var historyIndex = 0
    private var historyBytes: UnsafeMutablePointer<UInt8>?
    private var historyByteCount = 0

    private var selectionAnchor: Int?
    private var selectionHead = 0
    private var columns: UInt16 = 80
    private var rows: UInt16 = 24
    private var viewportRow: UInt16 = 0
    private var viewportPinned = false
    private var pending: PendingChange? = .snapshot
    private var pendingSequence: UInt32 = 1

    private var pasteActive = false
    private var pasteStart = 0
    private var pasteRemoved = 0
    private var pasteInserted = 0
    private var pasteBackup: UnsafeMutablePointer<UInt8>?
    private var pastePreviousPending: PendingChange?

    public init() {}

    deinit {
        heap?.deallocate()
        editBytes?.deallocate()
        historyBytes?.deallocate()
        pasteBackup?.deallocate()
    }

    public var count: Int { gapStart + storageCapacity - gapEnd }
    public var cursor: Int { gapStart }
    public var hasSelection: Bool { selectionAnchor != nil && selectionAnchor != selectionHead }
    public var visibleRows: UInt16 { ReixTextSurfaceFrameDescriptor.interactiveRows(for: rows) }

    public mutating func apply(_ event: ReixInputRecord) -> ShellEditorUpdate {
        pendingSequence = event.sequence
        if pasteActive { return applyPaste(event) }
        if event.kind == .resize { return resize(event) }
        if event.kind == .pasteBegin { return beginPaste() }
        if event.kind == .insert || event.kind == .textChunk || event.kind == .compositionCommit {
            return insertEvent(event)
        }
        if event.kind == .cancel { return cancel() }
        if event.kind == .eof { return count == 0 ? update(.eof, false) : refused() }
        if event.kind == .focusLost || event.kind == .stateReset { return refused() }
        guard event.kind == .key || legacyKeyKind(event.kind),
              event.phase != .release,
              let intent = intent(for: event)
        else { return refused() }
        if event.phase == .repeatKey {
            guard repeatable(intent) else { return refused() }
            return applyRepeated(intent, count: max(1, Int(event.repeatCount)))
        }
        return apply(intent)
    }

    @inline(__always)
    public mutating func withBytes<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        let savedCursor = cursor
        moveGap(to: count)
        let result = withStorage { body($0, count) }
        moveGap(to: savedCursor)
        return result
    }

    @inline(__always)
    public mutating func copyLine(into destination: inout InlineArray<8192, UInt8>) -> Int {
        withBytes { source, length in
            for index in 0..<length { destination[index] = source[index] }
            return length
        }
    }

    @inline(__always)
    public mutating func copyLine(into destination: inout InlineArray<256, UInt8>) -> Int {
        guard count <= destination.count else { return -1 }
        return withBytes { source, length in
            for index in 0..<length { destination[index] = source[index] }
            return length
        }
    }

    /// Presents prompt and input as one native frame without materializing 8 KiB.
    public mutating func withFrame(_ body: (ShellEditorFrameSource) -> Bool) -> Bool {
        guard let pending else { return true }
        guard let cursorPosition = framePosition(at: cursor) else { return false }
        followCursor(cursorPosition.row)
        let selection = selectionRange()
        var spans = InlineArray<4, ReixTextSurfaceStyleSpan?>(repeating: nil)
        var spanCount = 0
        spans[spanCount] = ReixTextSurfaceStyleSpan(
            offset: 0,
            length: UInt16(Self.promptBytes),
            role: .prompt
        )!
        spanCount += 1
        appendInputSpans(selection: selection, spans: &spans, count: &spanCount)
        let frame = frameMetadata(pending: pending, cursorPosition: cursorPosition)
        let result = withFrameText(pending: pending) { text in
            withUnsafeTemporaryAllocation(
                of: ReixTextSurfaceStyleSpan.self,
                capacity: spanCount
            ) { styles in
                for index in 0..<spanCount { styles[index] = spans[index]! }
                return body(
                    ShellEditorFrameSource(
                        frame: frame,
                        text0: text.0,
                        text0Length: text.1,
                        text1: text.2,
                        text1Length: text.3,
                        text2: text.4,
                        text2Length: text.5,
                        styles: UnsafePointer(styles.baseAddress!),
                        styleCount: spanCount
                    )
                )
            }
        }
        if result { self.pending = nil }
        return result
    }

    public mutating func reset() {
        resetBuffer()
        historyIndex = historyCount
        pending = .snapshot
    }

    private mutating func resize(_ event: ReixInputRecord) -> ShellEditorUpdate {
        guard event.width > 0,
              event.width <= ReixTextSurfaceFrameDescriptor.maximumColumns,
              event.height > 0,
              event.height <= ReixTextSurfaceFrameDescriptor.maximumRows
        else { return refused() }
        columns = event.width
        rows = event.height
        viewportPinned = false
        pending = .snapshot
        return update(.resized(event.width, event.height), true)
    }

    private mutating func beginPaste() -> ShellEditorUpdate {
        let range = selectionRange()
        let removed = range.1 - range.0
        if removed > 0 {
            let backup = UnsafeMutablePointer<UInt8>.allocate(capacity: removed)
            for index in 0..<removed { backup[index] = byte(at: range.0 + index) }
            pasteBackup = backup
        }
        pasteActive = true
        pastePreviousPending = pending
        pasteStart = range.0
        pasteRemoved = removed
        pasteInserted = 0
        deleteRange(range.0, range.1)
        selectionAnchor = nil
        selectionHead = gapStart
        return update(.editing, false)
    }

    private mutating func applyPaste(_ event: ReixInputRecord) -> ShellEditorUpdate {
        switch event.kind {
            case .pasteChunk:
                guard event.count > 0,
                      count <= Self.capacity - event.count,
                      ensureGap(event.count)
                else {
                    rollbackPaste()
                    return refused()
                }
                let insertionStart = gapStart
                let insertionCount = event.count
                let insertionText = event.text
                withMutableStorage { storage in
                    for index in 0..<insertionCount {
                        storage[insertionStart + index] = insertionText[index]
                    }
                }
                gapStart += event.count
                pasteInserted += event.count
                return update(.editing, false)
            case .pasteEnd:
                pasteActive = false
                recordPasteEdit()
                releasePasteBackup()
                if case nil = pastePreviousPending {
                    pending = .patch(offset: pasteStart, removed: pasteRemoved, inserted: pasteInserted)
                } else {
                    pending = .snapshot
                }
                pastePreviousPending = nil
                viewportPinned = false
                return update(.editing, true)
            default:
                rollbackPaste()
                return refused()
        }
    }

    private mutating func rollbackPaste() {
        deleteRange(pasteStart, pasteStart + pasteInserted)
        if pasteRemoved > 0, let pasteBackup, ensureGap(pasteRemoved) {
            let insertionStart = gapStart
            let removed = pasteRemoved
            let backup = pasteBackup
            withMutableStorage { storage in
                for index in 0..<removed {
                    storage[insertionStart + index] = backup[index]
                }
            }
            gapStart += removed
        }
        selectionAnchor = pasteRemoved == 0 ? nil : pasteStart
        selectionHead = pasteStart + pasteRemoved
        pasteActive = false
        pasteInserted = 0
        releasePasteBackup()
        pending = pastePreviousPending
        pastePreviousPending = nil
    }

    private mutating func insertEvent(_ event: ReixInputRecord) -> ShellEditorUpdate {
        guard event.count > 0 else { return refused() }
        let range = selectionRange()
        let removed = range.1 - range.0
        guard count - removed <= Self.capacity - event.count,
              ensureGap(event.count + removed)
        else { return refused() }
        recordEdit(
            offset: range.0,
            removed: removed,
            inserted: event.count,
            insertedBytes: event.text
        )
        deleteRange(range.0, range.1)
        let insertionStart = gapStart
        let insertionCount = event.count
        let insertionText = event.text
        withMutableStorage { storage in
            for index in 0..<insertionCount {
                storage[insertionStart + index] = insertionText[index]
            }
        }
        gapStart += event.count
        selectionAnchor = nil
        selectionHead = gapStart
        queuePatch(offset: range.0, removed: removed, inserted: event.count)
        viewportPinned = false
        return update(.editing, true)
    }

    private mutating func apply(_ intent: ShellEditorIntent) -> ShellEditorUpdate {
        switch intent {
            case .submit:
                prepareSubmission()
                remember()
                queueMetadata()
                return update(.submitted(count), true)
            case .submitOrNewline:
                let completeness = withBytes { TypedShellParser.completeness($0, count: $1) }
                if case .incomplete = completeness {
                    return insertNewline() ? update(.editing, true) : refused()
                }
                guard completeness == .complete else { return refused() }
                prepareSubmission()
                remember()
                queueMetadata()
                return update(.submitted(count), true)
            case .newline:
                return insertNewline() ? update(.editing, true) : refused()
            case .cancel:
                return cancel()
            case .eof:
                return count == 0 ? update(.eof, false) : refused()
            case .complete:
                return refused()
            default:
                break
        }
        guard applyOnce(intent) else { return refused() }
        return update(.editing, true)
    }

    private mutating func applyRepeated(
        _ intent: ShellEditorIntent,
        count repeats: Int
    ) -> ShellEditorUpdate {
        switch intent {
            case .moveLeft(let selecting):
                var target = cursor
                for _ in 0..<repeats {
                    guard let previous = boundaryBefore(target) else { return refused() }
                    target = previous
                }
                return move(to: target, selecting: selecting) ? update(.editing, true) : refused()
            case .moveRight(let selecting):
                var target = cursor
                for _ in 0..<repeats {
                    guard let next = boundaryAfter(target) else { return refused() }
                    target = next
                }
                return move(to: target, selecting: selecting) ? update(.editing, true) : refused()
            case .eraseBackward:
                var start = cursor
                for _ in 0..<repeats {
                    guard let previous = boundaryBefore(start) else { return refused() }
                    start = previous
                }
                return erase(range: (start, cursor)) ? update(.editing, true) : refused()
            case .eraseForward:
                var end = cursor
                for _ in 0..<repeats {
                    guard let next = boundaryAfter(end) else { return refused() }
                    end = next
                }
                return erase(range: (cursor, end)) ? update(.editing, true) : refused()
            case .home, .end:
                guard repeats == 1, applyOnce(intent) else { return refused() }
                return update(.editing, true)
            default:
                return refused()
        }
    }

    private mutating func applyOnce(_ intent: ShellEditorIntent) -> Bool {
        switch intent {
            case .moveLeft(let selecting): return move(to: boundaryBefore(cursor), selecting: selecting)
            case .moveRight(let selecting): return move(to: boundaryAfter(cursor), selecting: selecting)
            case .moveUp(let selecting):
                if moveVertical(up: true, selecting: selecting) { return true }
                return !selecting && recall(previous: true)
            case .moveDown(let selecting):
                if moveVertical(up: false, selecting: selecting) { return true }
                return !selecting && recall(previous: false)
            case .home(let selecting): return move(to: physicalRowBoundary(end: false), selecting: selecting)
            case .end(let selecting): return move(to: physicalRowBoundary(end: true), selecting: selecting)
            case .eraseBackward: return erase(backward: true)
            case .eraseForward: return erase(backward: false)
            case .submitOrNewline, .newline, .submit: return false
            case .historyPrevious: return recall(previous: true)
            case .historyNext: return recall(previous: false)
            case .pageUp: return scroll(up: true)
            case .pageDown: return scroll(up: false)
            case .undo: return undo()
            case .redo: return redo()
            case .cancel, .eof, .complete: return false
        }
    }

    private mutating func move(to offset: Int?, selecting: Bool) -> Bool {
        guard let offset, offset >= 0, offset <= count, offset != cursor else { return false }
        let previous = cursor
        moveGap(to: offset)
        if selecting {
            if selectionAnchor == nil { selectionAnchor = previous }
            selectionHead = offset
            if selectionAnchor == selectionHead { selectionAnchor = nil }
        } else {
            selectionAnchor = nil
            selectionHead = offset
        }
        queueMetadata()
        viewportPinned = false
        return true
    }

    private mutating func moveVertical(up: Bool, selecting: Bool) -> Bool {
        guard let current = framePosition(at: cursor) else { return false }
        let targetRow: UInt16
        if up {
            guard current.row > 0 else { return false }
            targetRow = current.row - 1
        } else {
            guard current.row < UInt16.max else { return false }
            targetRow = current.row + 1
        }
        let preferredColumn = current.row == 0 && current.column >= UInt16(Self.promptColumns)
            ? current.column - UInt16(Self.promptColumns)
            : current.column
        let wantedColumn = targetRow == 0
            ? preferredColumn + UInt16(Self.promptColumns)
            : preferredColumn
        let start = gapStart
        let gap = gapEnd - gapStart
        let inputCount = count
        let width = columns
        let candidate = withStorage { storage in
            ReixTextLayout.closestByteOffset(
                row: targetRow,
                column: min(wantedColumn, width - 1),
                count: Self.promptBytes + inputCount,
                columns: width,
                byte: { offset in
                    if offset < Self.promptBytes { return Self.prompt.utf8Start[offset] }
                    let logical = offset - Self.promptBytes
                    return storage[logical < start ? logical : logical + gap]
                }
            )
        }.map { max(0, $0 - Self.promptBytes) }
        return move(to: candidate, selecting: selecting)
    }

    private mutating func erase(backward: Bool) -> Bool {
        var range = selectionRange()
        if range.0 == range.1 {
            if backward {
                guard let start = boundaryBefore(cursor) else { return false }
                range = (start, cursor)
            } else {
                guard let end = boundaryAfter(cursor) else { return false }
                range = (cursor, end)
            }
        }
        return erase(range: range)
    }

    private mutating func erase(range: (Int, Int)) -> Bool {
        let removed = range.1 - range.0
        guard removed > 0 else { return false }
        recordEdit(
            offset: range.0,
            removed: removed,
            inserted: 0,
            insertedBytes: InlineArray<16, UInt8>(repeating: 0)
        )
        deleteRange(range.0, range.1)
        selectionAnchor = nil
        selectionHead = gapStart
        queuePatch(offset: range.0, removed: removed, inserted: 0)
        viewportPinned = false
        return true
    }

    private mutating func insertNewline() -> Bool {
        let range = selectionRange()
        let removed = range.1 - range.0
        guard count - removed < Self.capacity, ensureGap(1 + removed) else { return false }
        var newline = InlineArray<16, UInt8>(repeating: 0)
        newline[0] = 0x0A
        recordEdit(
            offset: range.0,
            removed: removed,
            inserted: 1,
            insertedBytes: newline
        )
        deleteRange(range.0, range.1)
        let insertionStart = gapStart
        withMutableStorage { $0[insertionStart] = 0x0A }
        gapStart += 1
        selectionAnchor = nil
        selectionHead = gapStart
        queuePatch(offset: range.0, removed: removed, inserted: 1)
        viewportPinned = false
        return true
    }

    private mutating func cancel() -> ShellEditorUpdate {
        resetBuffer()
        pending = .snapshot
        return update(.cancelled, true)
    }

    private mutating func scroll(up: Bool) -> Bool {
        guard let end = framePosition(at: count) else { return false }
        let maximum = end.row >= visibleRows ? end.row - visibleRows + 1 : 0
        let step = max(UInt16(1), visibleRows - 1)
        let targetViewport: UInt16
        if up {
            guard viewportRow > 0 else { return false }
            targetViewport = viewportRow > step ? viewportRow - step : 0
        } else {
            guard viewportRow < maximum else { return false }
            targetViewport = min(maximum, viewportRow + step)
        }
        var moved = false
        for _ in 0..<step {
            guard moveVertical(up: up, selecting: false) else { break }
            moved = true
        }
        guard moved, let cursorPosition = framePosition(at: cursor) else { return false }
        let minimum = cursorPosition.row >= visibleRows ? cursorPosition.row - visibleRows + 1 : 0
        viewportRow = min(cursorPosition.row, max(targetViewport, minimum))
        viewportPinned = true
        queueMetadata()
        return true
    }

    private mutating func undo() -> Bool {
        guard appliedEdits > 0, let record = edits[appliedEdits - 1] else { return false }
        guard replaceFromJournal(
            offset: record.offset,
            removed: record.insertedCount,
            insertedOffset: record.removedOffset,
            inserted: record.removedCount
        ) else { return false }
        appliedEdits -= 1
        queuePatch(
            offset: record.offset,
            removed: record.insertedCount,
            inserted: record.removedCount
        )
        viewportPinned = false
        return true
    }

    private mutating func redo() -> Bool {
        guard appliedEdits < editCount, let record = edits[appliedEdits] else { return false }
        guard replaceFromJournal(
            offset: record.offset,
            removed: record.removedCount,
            insertedOffset: record.insertedOffset,
            inserted: record.insertedCount
        ) else { return false }
        appliedEdits += 1
        queuePatch(
            offset: record.offset,
            removed: record.removedCount,
            inserted: record.insertedCount
        )
        viewportPinned = false
        return true
    }

    private mutating func replaceFromJournal(
        offset: Int,
        removed: Int,
        insertedOffset: Int,
        inserted: Int
    ) -> Bool {
        guard offset >= 0,
              removed >= 0,
              offset <= count,
              removed <= count - offset,
              count - removed <= Self.capacity - inserted,
              ensureGap(inserted + removed),
              let editBytes
        else { return false }
        deleteRange(offset, offset + removed)
        let insertionStart = gapStart
        let insertionBytes = editBytes
        withMutableStorage { storage in
            for index in 0..<inserted {
                storage[insertionStart + index] = insertionBytes[insertedOffset + index]
            }
        }
        gapStart += inserted
        selectionAnchor = nil
        selectionHead = gapStart
        return true
    }

    private mutating func recordEdit(
        offset: Int,
        removed: Int,
        inserted: Int,
        insertedBytes: InlineArray<16, UInt8>
    ) {
        clearRedo()
        let payload = removed + inserted
        guard payload <= Self.undoByteBudget, ensureEditStorage() else {
            clearEdits()
            return
        }
        while editCount == Self.undoCapacity || editByteCount > Self.undoByteBudget - payload {
            evictOldestEdit()
        }
        let removedOffset = editByteCount
        for index in 0..<removed { editBytes![editByteCount + index] = byte(at: offset + index) }
        editByteCount += removed
        let insertedOffset = editByteCount
        for index in 0..<inserted { editBytes![editByteCount + index] = insertedBytes[index] }
        editByteCount += inserted
        edits[editCount] = EditRecord(
            offset: offset,
            removedOffset: removedOffset,
            removedCount: removed,
            insertedOffset: insertedOffset,
            insertedCount: inserted
        )
        editCount += 1
        appliedEdits = editCount
    }

    private mutating func recordPasteEdit() {
        let payload = pasteRemoved + pasteInserted
        guard payload > 0 else { return }
        clearRedo()
        guard payload <= Self.undoByteBudget, ensureEditStorage() else {
            clearEdits()
            return
        }
        while editCount == Self.undoCapacity || editByteCount > Self.undoByteBudget - payload {
            evictOldestEdit()
        }
        let removedOffset = editByteCount
        if let pasteBackup {
            for index in 0..<pasteRemoved { editBytes![editByteCount + index] = pasteBackup[index] }
        }
        editByteCount += pasteRemoved
        let insertedOffset = editByteCount
        for index in 0..<pasteInserted {
            editBytes![editByteCount + index] = byte(at: pasteStart + index)
        }
        editByteCount += pasteInserted
        edits[editCount] = EditRecord(
            offset: pasteStart,
            removedOffset: removedOffset,
            removedCount: pasteRemoved,
            insertedOffset: insertedOffset,
            insertedCount: pasteInserted
        )
        editCount += 1
        appliedEdits = editCount
    }

    private mutating func releasePasteBackup() {
        pasteBackup?.deallocate()
        pasteBackup = nil
    }

    private mutating func clearRedo() {
        if appliedEdits < editCount {
            if appliedEdits == 0 { editByteCount = 0 }
            else { editByteCount = edits[appliedEdits - 1]!.payloadEnd }
            for index in appliedEdits..<editCount { edits[index] = nil }
            editCount = appliedEdits
        }
    }

    private mutating func evictOldestEdit() {
        guard editCount > 0, let first = edits[0] else { return }
        let removed = first.payloadCount
        if removed > 0, let editBytes {
            for index in removed..<editByteCount { editBytes[index - removed] = editBytes[index] }
        }
        for index in 1..<editCount {
            var record = edits[index]!
            record.removedOffset -= removed
            record.insertedOffset -= removed
            edits[index - 1] = record
        }
        edits[editCount - 1] = nil
        editCount -= 1
        appliedEdits = max(0, appliedEdits - 1)
        editByteCount -= removed
    }

    private mutating func ensureEditStorage() -> Bool {
        if editBytes != nil { return true }
        editBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.undoByteBudget)
        return editBytes != nil
    }

    private mutating func clearEdits() {
        for index in 0..<editCount { edits[index] = nil }
        editCount = 0
        appliedEdits = 0
        editByteCount = 0
    }

    private mutating func remember() {
        guard count > 0, count <= Self.historyByteBudget, ensureHistoryStorage() else {
            historyIndex = historyCount
            return
        }
        while historyCount == Self.historyCapacity || historyByteCount > Self.historyByteBudget - count {
            evictOldestHistory()
        }
        let offset = historyByteCount
        for index in 0..<count { historyBytes![offset + index] = byte(at: index) }
        history[historyCount] = HistoryRecord(offset: offset, count: count)
        historyCount += 1
        historyIndex = historyCount
        historyByteCount += count
    }

    private mutating func recall(previous: Bool) -> Bool {
        guard historyCount > 0 else { return false }
        if previous {
            guard historyIndex > 0 else { return false }
            historyIndex -= 1
        } else {
            guard historyIndex < historyCount else { return false }
            historyIndex += 1
            if historyIndex == historyCount {
                let oldCount = count
                resetBuffer()
                queuePatch(offset: 0, removed: oldCount, inserted: 0)
                return true
            }
        }
        guard let item = history[historyIndex], let historyBytes else { return false }
        let oldCount = count
        resetBuffer()
        guard ensureGap(item.count) else { return false }
        withMutableStorage { storage in
            for index in 0..<item.count { storage[index] = historyBytes[item.offset + index] }
        }
        gapStart = item.count
        selectionHead = gapStart
        queuePatch(offset: 0, removed: oldCount, inserted: item.count)
        return true
    }

    private mutating func evictOldestHistory() {
        guard historyCount > 0, let first = history[0] else { return }
        if let historyBytes {
            for index in first.count..<historyByteCount {
                historyBytes[index - first.count] = historyBytes[index]
            }
        }
        for index in 1..<historyCount {
            var item = history[index]!
            item.offset -= first.count
            history[index - 1] = item
        }
        history[historyCount - 1] = nil
        historyCount -= 1
        historyIndex = max(0, historyIndex - 1)
        historyByteCount -= first.count
    }

    private mutating func ensureHistoryStorage() -> Bool {
        if historyBytes != nil { return true }
        historyBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.historyByteBudget)
        return historyBytes != nil
    }

    private mutating func deleteRange(_ start: Int, _ end: Int) {
        guard start <= end else { return }
        moveGap(to: start)
        gapEnd += end - start
    }

    private mutating func ensureGap(_ amount: Int) -> Bool {
        if amount <= gapEnd - gapStart { return true }
        let needed = count + amount
        guard needed <= Self.capacity else { return false }
        var next = 1024
        while next < needed && next < Self.capacity { next *= 2 }
        return grow(to: next)
    }

    private mutating func grow(to next: Int) -> Bool {
        guard next > storageCapacity, next <= Self.capacity else { return next == storageCapacity }
        let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: next)
        let tail = storageCapacity - gapEnd
        withStorage { old in
            for index in 0..<gapStart { replacement[index] = old[index] }
            for index in 0..<tail { replacement[next - tail + index] = old[gapEnd + index] }
        }
        heap?.deallocate()
        heap = replacement
        storageCapacity = next
        gapEnd = next - tail
        return true
    }

    private mutating func moveGap(to offset: Int) {
        guard offset >= 0, offset <= count, offset != gapStart else { return }
        let start = gapStart
        let end = gapEnd
        withMutableStorage { storage in
            if offset < start {
                let amount = start - offset
                for index in 0..<amount { storage[end - amount + index] = storage[offset + index] }
            } else {
                let amount = offset - start
                for index in 0..<amount { storage[start + index] = storage[end + index] }
            }
        }
        if offset < start {
            gapStart = offset
            gapEnd = end - (start - offset)
        } else {
            gapStart = offset
            gapEnd = end + (offset - start)
        }
    }

    private func boundaryBefore(_ offset: Int) -> Int? {
        let start = gapStart
        let gap = gapEnd - gapStart
        let length = count
        return withStorage { storage in
            ReixTextLayout.previousGraphemeBoundary(before: offset, count: length) { index in
                storage[index < start ? index : index + gap]
            }
        }
    }

    private func boundaryAfter(_ offset: Int) -> Int? {
        guard offset < count else { return nil }
        let start = gapStart
        let gap = gapEnd - gapStart
        let length = count
        return withStorage { storage in
            ReixTextLayout.nextGraphemeBoundary(after: offset, count: length) { index in
                storage[index < start ? index : index + gap]
            }
        }
    }

    private func physicalRowBoundary(end: Bool) -> Int? {
        guard let current = framePosition(at: cursor) else { return nil }
        let targetColumn = end ? columns - 1 : 0
        let start = gapStart
        let gap = gapEnd - gapStart
        let inputCount = count
        let frameOffset = withStorage { storage -> Int? in
            let total = Self.promptBytes + inputCount
            let candidate = ReixTextLayout.closestByteOffset(
                row: current.row,
                column: targetColumn,
                count: total,
                columns: columns,
                byte: { offset in
                    if offset < Self.promptBytes { return Self.prompt.utf8Start[offset] }
                    let logical = offset - Self.promptBytes
                    return storage[logical < start ? logical : logical + gap]
                }
            )
            guard end,
                  let candidate,
                  candidate < total,
                  let position = ReixTextLayout.position(
                      at: candidate,
                      count: total,
                      columns: columns,
                      byte: { offset in
                          if offset < Self.promptBytes { return Self.prompt.utf8Start[offset] }
                          let logical = offset - Self.promptBytes
                          return storage[logical < start ? logical : logical + gap]
                      }
                  ),
                  position.row == current.row,
                  let next = ReixTextLayout.nextGraphemeBoundary(
                      after: candidate,
                      count: total,
                      byte: { offset in
                          if offset < Self.promptBytes { return Self.prompt.utf8Start[offset] }
                          let logical = offset - Self.promptBytes
                          return storage[logical < start ? logical : logical + gap]
                      }
                  ),
                  let width = ReixTextLayout.cellWidth(
                      from: candidate,
                      to: next,
                      count: total,
                      byte: { offset in
                          if offset < Self.promptBytes { return Self.prompt.utf8Start[offset] }
                          let logical = offset - Self.promptBytes
                          return storage[logical < start ? logical : logical + gap]
                      }
                  ),
                  width == columns - position.column
            else { return candidate }
            return next
        }
        return frameOffset.map { min(inputCount, max(0, $0 - Self.promptBytes)) }
    }

    private mutating func prepareSubmission() {
        moveGap(to: count)
        selectionAnchor = nil
        selectionHead = gapStart
        viewportPinned = false
    }

    private func framePosition(at inputOffset: Int) -> ReixTextLayout.Position? {
        let start = gapStart
        let gap = gapEnd - gapStart
        let inputCount = count
        let width = columns
        return withStorage { storage in
            ReixTextLayout.position(
                at: Self.promptBytes + inputOffset,
                count: Self.promptBytes + inputCount,
                columns: width,
                byte: { offset in
                    guard offset >= 0, offset < Self.promptBytes + inputCount else { return nil }
                    if offset < Self.promptBytes { return Self.prompt.utf8Start[offset] }
                    let logical = offset - Self.promptBytes
                    return storage[logical < start ? logical : logical + gap]
                }
            )
        }
    }

    private mutating func followCursor(_ cursorRow: UInt16) {
        guard !viewportPinned else { return }
        if cursorRow < viewportRow { viewportRow = cursorRow }
        else if cursorRow - viewportRow >= visibleRows {
            viewportRow = cursorRow - visibleRows + 1
        }
    }

    private func selectionRange() -> (Int, Int) {
        guard let anchor = selectionAnchor, anchor != selectionHead else { return (cursor, cursor) }
        return anchor < selectionHead ? (anchor, selectionHead) : (selectionHead, anchor)
    }

    private func intent(for event: ReixInputRecord) -> ShellEditorIntent? {
        if event.kind == .key {
            return ShellEditorKeymap.intent(key: event.logicalKey, modifiers: event.modifiers)
        }
        switch event.kind {
            case .left: return .moveLeft(false)
            case .right: return .moveRight(false)
            case .up: return .moveUp(false)
            case .down: return .moveDown(false)
            case .home: return .home(false)
            case .end: return .end(false)
            case .backspace: return .eraseBackward
            case .delete: return .eraseForward
            case .enter: return .submitOrNewline
            case .historyPrevious: return .historyPrevious
            case .historyNext: return .historyNext
            default: return nil
        }
    }

    private func legacyKeyKind(_ kind: ReixInputKind) -> Bool {
        switch kind {
            case .left, .right, .up, .down, .home, .end, .backspace, .delete,
                 .enter, .historyPrevious, .historyNext:
                return true
            default:
                return false
        }
    }

    private func repeatable(_ intent: ShellEditorIntent) -> Bool {
        switch intent {
            case .moveLeft, .moveRight, .home, .end, .eraseBackward, .eraseForward:
                return true
            default:
                return false
        }
    }

    private func frameMetadata(
        pending: PendingChange,
        cursorPosition: ReixTextLayout.Position
    ) -> ShellEditorFrame {
        let kind: ReixTextSurfaceFrameKind
        let offset: UInt32
        let removed: UInt32
        let length: UInt32
        switch pending {
            case .snapshot:
                kind = .snapshot
                offset = 0
                removed = 0
                length = UInt32(Self.promptBytes + count)
            case .patch(let patchOffset, let replaced, let inserted):
                kind = .patch
                offset = UInt32(Self.promptBytes + patchOffset)
                removed = UInt32(replaced)
                length = UInt32(inserted)
            case .metadata:
                kind = .patch
                offset = 0
                removed = 0
                length = 0
        }
        return ShellEditorFrame(
            kind: kind,
            correlation: pendingSequence,
            patchOffset: offset,
            replacedLength: removed,
            textLength: length,
            columns: columns,
            rows: rows,
            cursorOffset: UInt32(Self.promptBytes + cursor),
            cursorRow: cursorPosition.row,
            cursorColumn: cursorPosition.column,
            viewportRow: viewportRow,
            viewportRows: visibleRows
        )
    }

    private func appendInputSpans(
        selection: (Int, Int),
        spans: inout InlineArray<4, ReixTextSurfaceStyleSpan?>,
        count spanCount: inout Int
    ) {
        func append(_ start: Int, _ end: Int, _ role: ReixTextSurfaceStyleRole) {
            guard end > start else { return }
            spans[spanCount] = ReixTextSurfaceStyleSpan(
                offset: UInt32(Self.promptBytes + start),
                length: UInt16(end - start),
                role: role
            )!
            spanCount += 1
        }
        append(0, selection.0, .input)
        append(selection.0, selection.1, .selection)
        append(selection.1, count, .input)
    }

    private func withFrameText<R>(
        pending: PendingChange,
        _ body: ((UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
            UnsafePointer<UInt8>?, Int)) -> R
    ) -> R {
        withStorage { storage in
            switch pending {
                case .snapshot:
                    return body((
                        Self.prompt.utf8Start,
                        Self.promptBytes,
                        gapStart == 0 ? nil : UnsafePointer(storage),
                        gapStart,
                        gapEnd == storageCapacity ? nil : UnsafePointer(storage.advanced(by: gapEnd)),
                        storageCapacity - gapEnd
                    ))
                case .patch(let offset, _, let inserted):
                    return withLogicalRange(
                        offset: offset,
                        count: inserted,
                        storage: storage,
                        body
                    )
                case .metadata:
                    return body((nil, 0, nil, 0, nil, 0))
            }
        }
    }

    private func withLogicalRange<R>(
        offset: Int,
        count length: Int,
        storage: UnsafePointer<UInt8>,
        _ body: ((UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
            UnsafePointer<UInt8>?, Int)) -> R
    ) -> R {
        guard length > 0 else { return body((nil, 0, nil, 0, nil, 0)) }
        let first = min(length, max(0, gapStart - offset))
        let second = length - first
        let firstPointer = first == 0 ? nil : UnsafePointer(storage.advanced(by: offset))
        let secondLogical = offset + first
        let secondPhysical = physical(secondLogical)
        let secondPointer = second == 0 ? nil : UnsafePointer(storage.advanced(by: secondPhysical))
        return body((firstPointer, first, secondPointer, second, nil, 0))
    }

    private mutating func resetBuffer() {
        heap?.deallocate()
        heap = nil
        storageCapacity = Self.inlineCapacity
        gapStart = 0
        gapEnd = Self.inlineCapacity
        selectionAnchor = nil
        selectionHead = 0
        pasteActive = false
        pastePreviousPending = nil
        releasePasteBackup()
        viewportRow = 0
        viewportPinned = false
        clearEdits()
        editBytes?.deallocate()
        editBytes = nil
    }

    private func physical(_ offset: Int) -> Int {
        offset < gapStart ? offset : offset + gapEnd - gapStart
    }

    private func byte(at offset: Int) -> UInt8 {
        if let heap { return heap[physical(offset)] }
        return inline[physical(offset)]
    }

    private func withStorage<R>(_ body: (UnsafePointer<UInt8>) -> R) -> R {
        if let heap { return body(UnsafePointer(heap)) }
        return inline.span.withUnsafeBufferPointer {
            body($0.baseAddress!)
        }
    }

    private mutating func withMutableStorage<R>(
        _ body: (UnsafeMutablePointer<UInt8>) -> R
    ) -> R {
        if let heap { return body(heap) }
        return withUnsafeMutableBytes(of: &inline) {
            body($0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
    }

    private mutating func queuePatch(offset: Int, removed: Int, inserted: Int) {
        if case nil = pending {
            pending = .patch(offset: offset, removed: removed, inserted: inserted)
        } else {
            pending = .snapshot
        }
    }

    private mutating func queueMetadata() {
        if case nil = pending { pending = .metadata }
    }

    private func update(_ action: ShellEditorAction, _ frame: Bool) -> ShellEditorUpdate {
        ShellEditorUpdate(action: action, requiresPresentation: frame)
    }

    private func refused() -> ShellEditorUpdate {
        ShellEditorUpdate(action: .refused, requiresPresentation: false)
    }
}
