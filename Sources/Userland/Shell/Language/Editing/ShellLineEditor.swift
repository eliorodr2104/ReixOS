//
//  ShellLineEditor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

@_silgen_name("malloc")
private func shellEditorMalloc(_ size: UInt) -> UnsafeMutableRawPointer?

@_silgen_name("free")
private func shellEditorFree(_ pointer: UnsafeMutableRawPointer?)

/// Adds candidates that require live authority or state, synchronously, to the
/// bounded static result. The pointers are borrowed only for this call.
public typealias ShellDynamicCompleter = (
    _ snapshot: ShellAnalysisSnapshot,
    _ source  : UnsafePointer<UInt8>,
    _ count   : Int,
    _ offered : inout ShellCompletionSet
) -> Void

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

    private var selectionAnchor : Int?
    private var selectionHead   = 0
    private var columns         : UInt16         = 80
    private var rows            : UInt16         = 24
    private var viewportRow     : UInt16         = 0
    private var viewportPinned  = false
    private var pending         : PendingChange? = .snapshot
    private var pendingSequence : UInt32         = 1

    /// Bumped whenever the scene changes, which is whenever the bytes or the
    /// cursor move. An analysis is about one of these, and anything holding
    /// one has to ask whether it still describes the editor in hand.
    private var revisionCounter : UInt32 = 1
    private var codeEditing     = false

    private var pasteActive          = false
    private var pasteContainsNewline = false
    private var pasteStart           = 0
    private var pasteRemoved         = 0
    private var pasteInserted        = 0
    private var pasteBackup          : UnsafeMutablePointer<UInt8>?
    private var pastePreviousPending : PendingChange?
    private let allocationFault      : ShellEditorAllocationFault?
    private var allocationCounts     = InlineArray<4, Int>(repeating: 0)

    /// The box, when one is open, and the candidates behind it.
    ///
    /// Selecting in it changes nothing: the line moves when a candidate is
    /// accepted and not one keystroke before.
    private var panel       : ShellPanel?
    private var panelPrefix = Span(start: 0, count: 0)

    /// What tells a receiver or a verb from a plain word. Held here because it
    /// is read on every keystroke and it is the same catalog every time.
    private let catalog: ShellCatalog

    public init(
        catalog        : ShellCatalog = ShellCatalog(),
        allocationFault: ShellEditorAllocationFault? = nil
    ) {
        self.catalog = catalog
        self.allocationFault = allocationFault
    }

    deinit {
        Self.release(heap)
        Self.release(editBytes)
        Self.release(historyBytes)
        Self.release(pasteBackup)
    }

    public var count        : Int { gapStart + storageCapacity - gapEnd }
    public var cursor       : Int { gapStart }
    public var hasSelection : Bool { selectionAnchor != nil && selectionAnchor != selectionHead }
    public var isCodeEditing: Bool { codeEditing }
    public var visibleRows  : UInt16 { ReixTextSurfaceFrameDescriptor.interactiveRows(for: rows) }

    /// Which revision of the scene the next frame is about.
    public var revision: UInt32 { revisionCounter }

    public var isPanelOpen: Bool { panel != nil }

    public mutating func apply(_ event: ReixInputRecord) -> ShellEditorUpdate {
        apply(event, completingWith: Self.completeNothing)
    }

    public mutating func apply(
        _ event: ReixInputRecord,
          completingWith dynamic: ShellDynamicCompleter
    ) -> ShellEditorUpdate {
        pendingSequence = event.sequence
        if pasteActive { return applyPaste(event) }
        if event.kind == .resize { return resize(event) }
        if event.kind == .pasteBegin { return beginPaste() }
        if event.kind == .insert || event.kind == .textChunk || event.kind == .compositionCommit {
            // What the box offered was about the line as it was.
            closePanel()
            return insertEvent(event)
        }
        if event.kind == .focusLost || event.kind == .stateReset { return refused() }
        guard event.kind == .key,
              event.phase != .release,
              let intent = intent(for: event)
        else { return refused() }
        if event.phase == .repeatKey {
            guard repeatable(intent) else { return refused() }
            return applyRepeated(intent, count: max(1, Int(event.repeatCount)))
        }
        return apply(intent, completingWith: dynamic)
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
    /// Builds one frame of the scene, coloured by what the line means.
    ///
    /// An editor built without a catalog draws the line all the same: nothing
    /// resolves, so nothing is a receiver or a verb, which is the truth about
    /// a language nobody documented.
    public mutating func withFrame(_ body: (ShellEditorFrameSource) -> Bool) -> Bool {
        withFrame(completingWith: Self.completeNothing, body)
    }

    public mutating func withFrame(
        completingWith dynamic: ShellDynamicCompleter,
        _ body: (ShellEditorFrameSource) -> Bool
    ) -> Bool {
        guard let pending else { return true }
        guard let cursorPosition = framePosition(at: cursor) else { return false }
        let endPosition: ReixTextLayout.Position
        if cursor == count {
            endPosition = cursorPosition
        } else {
            guard let position = framePosition(at: count) else { return false }
            endPosition = position
        }
        let contentRows = max(UInt16(1), endPosition.row + 1)
        let chromeRows  = codeEditing
            ? ReixCodeEditorLayout.footerRows(for: visibleRows)
            : 0
        let desiredRows = contentRows <= UInt16.max - chromeRows
            ? contentRows + chromeRows
            : UInt16.max
        let viewportRows       = min(visibleRows, desiredRows)
        let cursorViewportRows = codeEditing
            ? max(1, ReixCodeEditorLayout.contentViewportRows(for: viewportRows))
            : viewportRows
        followCursor(cursorPosition.row, viewportRows: cursorViewportRows)
        let selection = selectionRange()
        var spans     = InlineArray<64, ReixTextSurfaceStyleSpan?>(repeating: nil)
        var spanCount = 0
        if !codeEditing {
            spans[spanCount] = ReixTextSurfaceStyleSpan(
                offset: 0,
                length: UInt16(Self.promptBytes),
                role: .prompt
            )!
            spanCount += 1
        }
        let snapshot = analysis()
        appendInputSpans(snapshot, selection: selection, spans: &spans, count: &spanCount)
        let ghost      = suggestion(for: snapshot, completingWith: dynamic)
        let ghostTyped = ghost?.replacement.count ?? 0

        // The panel takes the rows the input is not using, and none of the
        // ones it is.
        let room = visibleRows > viewportRows ? visibleRows - viewportRows : 0
        let result = withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity: ShellPanelPainter.byteCapacity
        ) { overlayBytes in
            withUnsafeTemporaryAllocation(
                of: ReixTextSurfaceStyleSpan.self,
                capacity: ShellPanelPainter.spanCapacity
            ) { overlaySpans in
                var geometry: ShellPanelGeometry?
                var panelRow = UInt16(0)
                var panelRows = UInt16(0)
                if let panel, room > 0 {
                    geometry = ShellPanelPainter.paint(
                        panel,
                        columns: columns,
                        rows: room,
                        into: overlayBytes.baseAddress!,
                        spans: overlaySpans.baseAddress!
                    )
                    panelRows = geometry?.rows ?? 0
                    panelRow = panelRows == 0 ? 0 : viewportRows
                } else if let ghost, cursorPosition.column < columns {
                    // The grey word sits where the cursor is, on the row the
                    // cursor is on, and takes no row of its own.
                    geometry = ghost.candidate.withName { bytes, length in
                        ShellPanelPainter.ghost(
                            bytes.advanced(by: ghostTyped),
                            count: length - ghostTyped,
                            room : columns - cursorPosition.column,
                            into : overlayBytes.baseAddress!,
                            spans: overlaySpans.baseAddress!
                        )
                    }
                    if geometry != nil { panelRow = cursorPosition.row - viewportRow }
                }
                let frame = frameMetadata(
                    pending: pending,
                    cursorPosition: cursorPosition,
                    viewportRows: viewportRows,
                    presentationRows: viewportRows + panelRows,
                    panelRow: panelRow,
                    panelColumn: panelRows == 0 ? cursorPosition.column : 0,
                    panel: geometry
                )
                return withFrameText(pending: pending) { text in
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
                                styles: spanCount == 0 ? nil : UnsafePointer(styles.baseAddress!),
                                styleCount: spanCount,
                                overlay: geometry == nil ? nil : UnsafePointer(overlayBytes.baseAddress!),
                                overlayLength: geometry?.byteCount ?? 0,
                                overlayStyles: (geometry?.spanCount ?? 0) == 0
                                    ? nil
                                    : UnsafePointer(overlaySpans.baseAddress!),
                                overlayStyleCount: geometry?.spanCount ?? 0
                            )
                        )
                    }
                }
            }
        }
        if result { self.pending = nil }
        return result
    }

    /// Makes the next frame carry the whole line. A patch is only meaningful to a
    /// consumer that took the one before it.
    public mutating func requireSnapshot() {
        pending = .snapshot
    }

    public mutating func reset() {
        resetBuffer()
        codeEditing = false
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
            guard let backup = allocate(capacity: removed, site: .pasteBackup) else {
                return refused()
            }
            for index in 0..<removed { backup[index] = byte(at: range.0 + index) }
            pasteBackup = backup
        }
        pasteActive = true
        pasteContainsNewline = false
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
                for index in 0..<insertionCount where insertionText[index] == 0x0A {
                    pasteContainsNewline = true
                }
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
                if pasteContainsNewline && !codeEditing {
                    codeEditing = true
                    pending = .snapshot
                } else if case nil = pastePreviousPending {
                    pending = .patch(offset: pasteStart, removed: pasteRemoved, inserted: pasteInserted)
                } else {
                    pending = .snapshot
                }
                pasteContainsNewline = false
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
        pasteContainsNewline = false
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

    private mutating func apply(
        _ intent: ShellEditorIntent,
          completingWith dynamic: ShellDynamicCompleter
    ) -> ShellEditorUpdate {
        // While the box is open the keys that move a selection belong to it,
        // and nothing they do reaches the line.
        if panel != nil {
            switch intent {
                case .complete:
                    panel?.step(1)
                    pending = .snapshot
                    return update(.editing, true)
                case .completePrevious, .moveUp:
                    panel?.step(-1)
                    pending = .snapshot
                    return update(.editing, true)
                case .moveDown:
                    panel?.step(1)
                    pending = .snapshot
                    return update(.editing, true)
                case .pageUp:
                    panel?.step(-ShellPanel.rowCapacity)
                    pending = .snapshot
                    return update(.editing, true)
                case .pageDown:
                    panel?.step(ShellPanel.rowCapacity)
                    pending = .snapshot
                    return update(.editing, true)
                case .cancel:
                    closePanel()
                    return update(.editing, true)
                case .submit, .submitOrNewline:
                    return acceptPanel() ? update(.editing, true) : refused()
                default:
                    closePanel()
            }
        }
        if codeEditing {
            switch intent {
                case .historyPrevious, .historyNext:
                    return update(.editing, false)
                default:
                    break
            }
        }
        switch intent {
            case .submit:
                prepareSubmission()
                remember()
                queueMetadata()
                return update(.submitted(count), true)
            case .submitOrNewline:
                if codeEditing {
                    return insertNewline() ? update(.editing, true) : refused()
                }
                let completeness = withBytes { TypedShellParser.completeness($0, count: $1) }
                if case .incomplete = completeness {
                    codeEditing = true
                    pending = .snapshot
                    return insertNewline() ? update(.editing, true) : refused()
                }
                guard completeness == .complete else { return refused() }
                prepareSubmission()
                remember()
                queueMetadata()
                return update(.submitted(count), true)
            case .newline:
                if !codeEditing {
                    codeEditing = true
                    pending = .snapshot
                    if count == 0 { return update(.editing, true) }
                }
                return insertNewline() ? update(.editing, true) : refused()
            case .cancel:
                return cancel()
            case .eof:
                return count == 0 ? update(.eof, false) : refused()
            case .complete, .completePrevious:
                // Completion owns Tab in editor mode too. At indentation it
                // first answers the semantic context carried across the
                // newline. A fresh top-level line remains ordinary code
                // indentation even though the global catalog is non-empty.
                let snapshot = analysis()
                if codeEditing, atLineIndent(), snapshot.context.subject == .receiverOrCommand {
                    return insertIndent() ? update(.editing, true) : refused()
                }
                if intent == .complete, acceptSuggestion(for: snapshot, completingWith: dynamic) {
                    return update(.editing, true)
                }
                if openPanel(for: snapshot, completingWith: dynamic) { return update(.editing, true) }
                return codeEditing && insertIndent() ? update(.editing, true) : refused()
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
                return codeEditing || !selecting && recall(previous: true)
            case .moveDown(let selecting):
                if moveVertical(up: false, selecting: selecting) { return true }
                return codeEditing || !selecting && recall(previous: false)
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
            case .cancel, .eof, .complete, .completePrevious: return false
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
            let firstEditableRow = codeEditing ? ReixCodeEditorLayout.headerRows : 0
            guard current.row > firstEditableRow else { return false }
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
            if codeEditing {
                let gutter          = ReixCodeEditorLayout.gutterColumns(for: width)
                let preferredColumn = current.column >= gutter ? current.column - gutter : 0
                return ReixCodeEditorLayout.closestByteOffset(
                    row: targetRow,
                    column: min(gutter + preferredColumn, width - 1),
                    count: inputCount,
                    columns: width,
                    byte: { offset in
                        storage[offset < start ? offset : offset + gap]
                    }
                )
            }
            return ReixTextLayout.closestByteOffset(
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
        }.map { codeEditing ? $0 : max(0, $0 - Self.promptBytes) }
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

    private mutating func insertIndent() -> Bool {
        let range    = selectionRange()
        let removed  = range.1 - range.0
        let inserted = 4
        guard count - removed <= Self.capacity - inserted,
              ensureGap(inserted + removed)
        else { return false }
        var spaces = InlineArray<16, UInt8>(repeating: 0)
        for index in 0..<inserted { spaces[index] = 0x20 }
        recordEdit(
            offset: range.0,
            removed: removed,
            inserted: inserted,
            insertedBytes: spaces
        )
        deleteRange(range.0, range.1)
        let insertionStart = gapStart
        withMutableStorage { storage in
            for index in 0..<inserted { storage[insertionStart + index] = 0x20 }
        }
        gapStart += inserted
        selectionAnchor = nil
        selectionHead = gapStart
        queuePatch(offset: range.0, removed: removed, inserted: inserted)
        viewportPinned = false
        return true
    }

    private mutating func cancel() -> ShellEditorUpdate {
        resetBuffer()
        codeEditing = false
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
        Self.release(pasteBackup)
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
        editBytes = allocate(capacity: Self.undoByteBudget, site: .undo)
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
        historyBytes = allocate(capacity: Self.historyByteBudget, site: .history)
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
        guard let replacement = allocate(capacity: next, site: .storage) else { return false }
        let tail = storageCapacity - gapEnd
        withStorage { old in
            for index in 0..<gapStart { replacement[index] = old[index] }
            for index in 0..<tail { replacement[next - tail + index] = old[gapEnd + index] }
        }
        Self.release(heap)
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
                // Source and destination overlap when the move is wider than the
                // gap, so copy backwards: this is the right-shift half of memmove.
                for index in stride(from: amount - 1, through: 0, by: -1) {
                    storage[end - amount + index] = storage[offset + index]
                }
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
        let targetColumn = end
            ? columns - 1
            : codeEditing ? ReixCodeEditorLayout.gutterColumns(for: columns) : 0
        let start = gapStart
        let gap = gapEnd - gapStart
        let inputCount = count

        let frameOffset = withStorage { storage -> Int? in
            if codeEditing {
                let candidate = ReixCodeEditorLayout.closestByteOffset(
                    row: current.row,
                    column: targetColumn,
                    count: inputCount,
                    columns: columns,
                    byte: { offset in storage[offset < start ? offset : offset + gap] }
                )
                guard end,
                      let candidate,
                      candidate < inputCount,
                      let position = ReixCodeEditorLayout.position(
                          at: candidate,
                          count: inputCount,
                          columns: columns,
                          byte: { offset in storage[offset < start ? offset : offset + gap] }
                      ),
                      position.row == current.row,
                      let next = ReixTextLayout.nextGraphemeBoundary(
                          after: candidate,
                          count: inputCount,
                          byte: { offset in storage[offset < start ? offset : offset + gap] }
                      ),
                      let width = ReixTextLayout.cellWidth(
                          from: candidate,
                          to: next,
                          count: inputCount,
                          byte: { offset in storage[offset < start ? offset : offset + gap] }
                      ),
                      width == columns - position.column
                else { return candidate }
                return next
            }
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
        return frameOffset.map {
            codeEditing ? min(inputCount, max(0, $0)) : min(inputCount, max(0, $0 - Self.promptBytes))
        }
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
            if codeEditing {
                return ReixCodeEditorLayout.position(
                    at: inputOffset,
                    count: inputCount,
                    columns: width,
                    byte: { offset in
                        guard offset >= 0, offset < inputCount else { return nil }
                        return storage[offset < start ? offset : offset + gap]
                    }
                )
            }
            return ReixTextLayout.position(
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

    private mutating func followCursor(
        _ cursorRow: UInt16,
        viewportRows: UInt16
    ) {
        guard !viewportPinned else { return }
        if codeEditing && cursorRow == ReixCodeEditorLayout.headerRows {
            viewportRow = 0
        } else if cursorRow < viewportRow { viewportRow = cursorRow }
        else if cursorRow - viewportRow >= viewportRows {
            viewportRow = cursorRow - viewportRows + 1
        }
    }

    private func selectionRange() -> (Int, Int) {
        guard let anchor = selectionAnchor, anchor != selectionHead else { return (cursor, cursor) }
        return anchor < selectionHead ? (anchor, selectionHead) : (selectionHead, anchor)
    }

    private func intent(for event: ReixInputRecord) -> ShellEditorIntent? {
        guard event.kind == .key else { return nil }
        return ShellEditorKeymap.intent(key: event.logicalKey, modifiers: event.modifiers)
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
        cursorPosition: ReixTextLayout.Position,
        viewportRows: UInt16,
        presentationRows: UInt16,
        panelRow: UInt16 = 0,
        panelColumn: UInt16 = 0,
        panel: ShellPanelGeometry? = nil
    ) -> ShellEditorFrame {
        let prefixBytes = codeEditing ? 0 : Self.promptBytes
        let kind        : ReixTextSurfaceFrameKind
        let offset      : UInt32
        let removed     : UInt32
        let length      : UInt32
        switch pending {
            case .snapshot:
                kind = .snapshot
                offset = 0
                removed = 0
                length = UInt32(prefixBytes + count)
            case .patch(let patchOffset, let replaced, let inserted):
                kind = .patch
                offset = UInt32(prefixBytes + patchOffset)
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
            mode: codeEditing ? .codeEditor : .editor,
            correlation: pendingSequence,
            patchOffset: offset,
            replacedLength: removed,
            textLength: length,
            columns: columns,
            rows: rows,
            cursorOffset: UInt32(prefixBytes + cursor),
            cursorRow: cursorPosition.row,
            cursorColumn: cursorPosition.column,
            viewportRow: viewportRow,
            viewportRows: viewportRows,
            presentationRows: presentationRows,
            overlayRow: panelRow,
            overlayColumn: panel == nil ? 0 : panelColumn,
            overlayRows: panel?.rows ?? 0,
            overlayColumns: panel?.columns ?? 0
        )
    }

    /// Opens the box on what would fit where the cursor is.
    ///
    /// Nothing to offer is not a failure of the box; it is an answer, and the
    /// caller decides what to do with a Tab that has nothing to complete.
    private mutating func openPanel(
        for snapshot: ShellAnalysisSnapshot,
        completingWith dynamic: ShellDynamicCompleter
    ) -> Bool {
        let offered  = completions(for: snapshot, completingWith: dynamic)
        guard offered.count > 0 else { return false }
        panelPrefix = snapshot.context.prefix
        panel = ShellPanel.candidates(offered, title: Self.title(for: snapshot.context.subject))
        pending = .snapshot
        return true
    }

    /// The one candidate that would finish what is being typed.
    ///
    /// Only at the end of the line, only with something typed to extend, and
    /// only from what is documented: this is the static side, so it never
    /// asks a disk anything and never survives a keystroke.
    private mutating func suggestion(
        for snapshot: ShellAnalysisSnapshot,
        completingWith dynamic: ShellDynamicCompleter
    ) -> (candidate: ShellCompletion, replacement: Span)? {
        guard panel == nil, cursor == count else { return nil }
        let offered = completions(for: snapshot, completingWith: dynamic)
        guard let best = offered.candidate(at: 0) else { return nil }
        let replacement = best.replacement ?? snapshot.context.prefix
        guard replacement.isInside(count),
              replacement.start + replacement.count == cursor,
              (replacement.count > 0 || best.kind == .path),
              best.count > replacement.count
        else { return nil }
        return (best, replacement)
    }

    /// Writes the rest of what was suggested, and whatever follows it.
    private mutating func acceptSuggestion(
        for snapshot: ShellAnalysisSnapshot,
        completingWith dynamic: ShellDynamicCompleter
    ) -> Bool {
        guard let suggestion = suggestion(for: snapshot, completingWith: dynamic) else { return false }
        let best  = suggestion.candidate
        let typed = suggestion.replacement.count
        // With no leaf yet, grey text is a preview and Tab opens the choice
        // box instead of silently picking its first row.
        guard typed > 0 else { return false }
        var written = best.withName { bytes, length in
            insertRun(bytes.advanced(by: typed), length - typed)
        }
        if written, best.suffix.utf8CodeUnitCount > 0 {
            written = insertRun(best.suffix.utf8Start, best.suffix.utf8CodeUnitCount)
        }
        if written { stepBack(best.caret) }
        return written
    }

    /// Whether nothing but blanks stands between the cursor and the start of
    /// its line.
    private mutating func atLineIndent() -> Bool {
        let position = cursor
        return withBytes { source, _ in
            var index = position
            while index > 0 {
                let byte = source[index - 1]
                if byte == 0x0A { return true }
                if byte != 0x20 && byte != 0x09 { return false }
                index -= 1
            }
            return true
        }
    }

    private mutating func closePanel() {
        guard panel != nil else { return }
        panel = nil
        panelPrefix = Span(start: 0, count: 0)
        pending = .snapshot
    }

    /// Writes the selected candidate over what was typed of it.
    private mutating func acceptPanel() -> Bool {
        guard let candidate = panel?.selection else {
            closePanel()
            return false
        }
        let replacement = candidate.replacement ?? panelPrefix
        let start = replacement.start
        guard replacement.isInside(count),
              replacement.start + replacement.count == cursor,
              start >= 0, start <= cursor, cursor <= count
        else {
            closePanel()
            return false
        }
        if cursor > start {
            selectionAnchor = start
            selectionHead = cursor
        }
        var written = candidate.withName { bytes, length in insertRun(bytes, length) }
        if written, candidate.suffix.utf8CodeUnitCount > 0 {
            written = insertRun(candidate.suffix.utf8Start, candidate.suffix.utf8CodeUnitCount)
        }
        if written { stepBack(candidate.caret) }
        closePanel()
        return written
    }

    /// Puts the cursor back inside what was just written, which is where
    /// somebody accepting `filter { }` wants to be.
    private mutating func stepBack(_ places: Int) {
        guard places > 0 else { return }
        for _ in 0..<places where !applyOnce(.moveLeft(false)) { return }
    }

    /// Inserts a run of bytes through the ordinary insertion path, in the
    /// sixteen-byte pieces an input record carries, so the journal, the patch
    /// and the selection all behave as if it had been typed.
    private mutating func insertRun(
        _ bytes : UnsafePointer<UInt8>,
        _ length: Int
    ) -> Bool {
        var offset = 0
        while offset < length {
            let chunk = min(ReixInputProtocol.maximumPayload, length - offset)
            guard let record = ReixInputRecord(
                kind    : .insert,
                sequence: pendingSequence,
                bytes   : bytes.advanced(by: offset),
                count   : chunk
            ) else { return false }
            guard insertEvent(record).action == .editing else { return false }
            offset += chunk
        }
        return true
    }

    private static func title(for subject: ShellCompletionSubject) -> StaticString {
        switch subject {
            case .none: return "nothing"
            case .receiverOrCommand: return "receivers and verbs"
            case .command: return "verbs"
            case .label: return "labels"
            case .member: return "members"
            case .value: return "values"
        }
    }

    /// The analysis of the line as it stands, about this revision.
    ///
    /// A whole reading every frame. It costs a gap move and one pass over the
    /// bytes, which is small against what the frame itself costs, and it is
    /// what keeps the colours from ever describing bytes that have moved.
    private mutating func analysis() -> ShellAnalysisSnapshot {
        let position = cursor
        let stamp    = revisionCounter
        // By pointer, not by copy: the catalog is thousands of bytes and this
        // runs on every frame.
        return withUnsafePointer(to: catalog) { table in
            withBytes { source, count in
                ShellAnalyzer.analyze(
                    source,
                    count   : count,
                    cursor  : position,
                    revision: stamp,
                    catalog : table.pointee
                )
            }
        }
    }

    /// Static and live candidates share one bounded set and one ordering.
    /// The live provider is called only when completion is actually painted or
    /// accepted, never for ordinary cursor or panel movement.
    private mutating func completions(
        for snapshot: ShellAnalysisSnapshot,
        completingWith dynamic: ShellDynamicCompleter
    ) -> ShellCompletionSet {
        withUnsafePointer(to: catalog) { table in
            withBytes { source, length in
                var offered = ShellCompletionEngine.complete(
                    for    : snapshot,
                    source : source,
                    count  : length,
                    catalog: table.pointee
                )
                dynamic(snapshot, source, length, &offered)
                return offered
            }
        }
    }

    private static func completeNothing(
        _ snapshot: ShellAnalysisSnapshot,
        _ source  : UnsafePointer<UInt8>,
        _ count   : Int,
        _ offered : inout ShellCompletionSet
    ) {}

    /// Turns what the line means into what the frame carries.
    ///
    /// Spans arrive sorted and apart: a selection takes its range and the
    /// colours are cut around it. What overruns the frame's budget is left
    /// plain, so the frame stays inside what the transport carries.
    private func appendInputSpans(
        _ snapshot     : ShellAnalysisSnapshot,
        selection      : (Int, Int),
        spans          : inout InlineArray<64, ReixTextSurfaceStyleSpan?>,
        count spanCount: inout Int
    ) {
        let prefixBytes = codeEditing ? 0 : Self.promptBytes
        func append(_ start: Int, _ end: Int, _ role: ReixTextSurfaceStyleRole) {
            guard end > start, spanCount < spans.count,
                  let span = ReixTextSurfaceStyleSpan(
                      offset: UInt32(prefixBytes + start),
                      length: UInt16(end - start),
                      role: role
                  )
            else { return }
            spans[spanCount] = span
            spanCount += 1
        }

        let selectionStart = selection.0
        let selectionEnd   = selection.1
        var selectionLeft  = selectionEnd > selectionStart

        for index in 0..<snapshot.spanCount {
            guard let semantic = snapshot.span(at: index) else { continue }
            let role = Self.styleRole(for: semantic.role)
            guard role != .input else { continue }
            let start = Int(semantic.start)
            let end   = min(semantic.end, count)
            guard end > start else { continue }

            if !selectionLeft || end <= selectionStart {
                append(start, end, role)
                continue
            }
            if start < selectionStart { append(start, selectionStart, role) }
            if selectionLeft, selectionStart <= start || start < selectionStart {
                append(selectionStart, selectionEnd, .selection)
                selectionLeft = false
            }
            if end > selectionEnd { append(max(start, selectionEnd), end, role) }
        }
        if selectionLeft { append(selectionStart, selectionEnd, .selection) }
    }

    /// One place where a meaning becomes a role on the wire. A switch, so a
    /// meaning added to the language cannot arrive here undressed.
    private static func styleRole(for role: ShellSemanticRole) -> ReixTextSurfaceStyleRole {
        switch role {
            case .plain: return .input
            case .keyword: return .keyword
            case .namespace: return .namespace
            case .command: return .command
            case .label: return .label
            case .text: return .text
            case .number: return .number
            case .path: return .path
            case .variable: return .variable
            case .member: return .member
            case .closure: return .closure
            case .incomplete: return .incomplete
            case .error: return .error
        }
    }

    private func withFrameText<R>(
        pending: PendingChange,
        _ body: ((UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
            UnsafePointer<UInt8>?, Int)) -> R
    ) -> R {
        withStorage { storage in
            switch pending {
                case .snapshot:
                    if codeEditing {
                        return body((
                            gapStart == 0 ? nil : UnsafePointer(storage),
                            gapStart,
                            gapEnd == storageCapacity ? nil : UnsafePointer(storage.advanced(by: gapEnd)),
                            storageCapacity - gapEnd,
                            nil,
                            0
                        ))
                    }
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
        Self.release(heap)
        heap = nil
        storageCapacity = Self.inlineCapacity
        gapStart = 0
        gapEnd = Self.inlineCapacity
        selectionAnchor = nil
        selectionHead = 0
        pasteActive = false
        pasteContainsNewline = false
        pastePreviousPending = nil
        releasePasteBackup()
        viewportRow = 0
        viewportPinned = false
        clearEdits()
        Self.release(editBytes)
        editBytes = nil
    }

    private mutating func allocate(
        capacity: Int,
        site    : ShellEditorAllocationSite
    ) -> UnsafeMutablePointer<UInt8>? {
        guard capacity > 0 else { return nil }
        let index = Int(site.rawValue)
        allocationCounts[index] += 1
        if let allocationFault,
           allocationFault.site == site,
           allocationFault.occurrence == allocationCounts[index] {
            return nil
        }
        return shellEditorMalloc(UInt(capacity))?.assumingMemoryBound(to: UInt8.self)
    }

    private static func release(_ pointer: UnsafeMutablePointer<UInt8>?) {
        shellEditorFree(pointer.map(UnsafeMutableRawPointer.init))
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

    private mutating func update(
        _ action: ShellEditorAction,
        _ frame : Bool
    ) -> ShellEditorUpdate {
        if frame { revisionCounter = revisionCounter &+ 1 }
        return ShellEditorUpdate(action: action, requiresPresentation: frame)
    }

    private func refused() -> ShellEditorUpdate {
        ShellEditorUpdate(action: .refused, requiresPresentation: false)
    }
}
