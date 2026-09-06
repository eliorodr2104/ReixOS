//
//  ShellEditorTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

@Suite("Bounded shell editor")
struct ShellEditorTests {
    @Test("gap storage promotes through every bounded size and refuses 8193")
    func gapSizesAndOverflow() {
        for size in [1, 64, 256, 384, 1024, 2048, 4096, 8192] {
            var editor = ShellLineEditor()
            var sequence: UInt32 = 1
            insert([UInt8](repeating: 0x61, count: size), into: &editor, sequence: &sequence)
            let seededCount = editor.count
            #expect(seededCount == size)
            let before = editor.cursor
            let refused = insertByte(0x78, into: &editor, sequence: &sequence)
            if size == ShellLineEditor.capacity {
                #expect(refused.action == .refused)
                let finalCount = editor.count
                let finalCursor = editor.cursor
                #expect(finalCount == size)
                #expect(finalCursor == before)
            }
        }
    }

    @Test("scoped reads preserve the cursor and submission owns the whole buffer")
    func scopedReadAndSubmissionCursor() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        insert(Array("abcd".utf8), into: &editor, sequence: &sequence)
        _ = editor.apply(key(.left, sequence: sequence))
        _ = editor.apply(key(.left, sequence: sequence + 1))
        let savedCursor = editor.cursor
        #expect(bytes(of: &editor) == Array("abcd".utf8))
        #expect(editor.cursor == savedCursor)

        let newline = editor.apply(key(.enter, sequence: sequence + 2, modifiers: [.shift]))
        #expect(newline.action == .editing)
        #expect(bytes(of: &editor) == Array("ab\ncd".utf8))
        #expect(editor.cursor == 3)

        _ = editor.apply(key(.left, sequence: sequence + 3))
        let submitted = editor.apply(key(.enter, sequence: sequence + 4, modifiers: [.control]))
        #expect(submitted.action == .submitted(5))
        #expect(editor.cursor == editor.count)

        editor.reset()
        insert(Array("list.filter {".utf8), into: &editor, sequence: &sequence)
        _ = editor.apply(key(.left, sequence: sequence))
        let insertionPoint = editor.cursor
        let continued = editor.apply(key(.enter, sequence: sequence + 1))
        var expected = Array("list.filter {".utf8)
        expected.insert(0x0A, at: insertionPoint)
        #expect(continued.action == .editing)
        #expect(bytes(of: &editor) == expected)
        #expect(editor.cursor == insertionPoint + 1)
    }

    @Test("plain input styles do not split when the cursor moves")
    func cursorMetadataKeepsCanonicalStyles() {
        var editor   = ShellLineEditor()
        var sequence : UInt32 = 1
        #expect(editor.withFrame { _ in true })
        insert(Array("abc".utf8), into: &editor, sequence: &sequence)
        var insertedStyleCount = 0
        #expect(editor.withFrame {
            insertedStyleCount = $0.styleCount
            return true
        })

        let moved = editor.apply(key(.left, sequence: sequence))
        #expect(moved.requiresPresentation)
        var movedStyleCount = 0
        var movedTextLength : UInt32 = 1
        #expect(editor.withFrame {
            movedStyleCount = $0.styleCount
            movedTextLength = $0.frame.textLength
            return true
        })
        #expect(insertedStyleCount == 2)
        #expect(movedStyleCount == insertedStyleCount)
        #expect(movedTextLength == 0)
    }

    @Test("Home and End follow physical soft-wrapped rows")
    func physicalHomeAndEnd() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        _ = editor.apply(ReixInputRecord(kind: .resize, sequence: sequence, width: 10, height: 8)!)
        sequence += 1
        insert(Array("abcdefghij".utf8), into: &editor, sequence: &sequence)

        #expect(editor.apply(key(.home, sequence: sequence)).action == .editing)
        #expect(editor.cursor == 4)
        #expect(editor.apply(key(.end, sequence: sequence + 1)).action == .editing)
        #expect(editor.cursor == 10)

        for offset in 0..<7 {
            _ = editor.apply(key(.left, sequence: sequence + 2 + UInt32(offset)))
        }
        #expect(editor.cursor == 3)
        #expect(editor.apply(key(.home, sequence: sequence + 9)).action == .editing)
        #expect(editor.cursor == 0)
        #expect(editor.apply(key(.end, sequence: sequence + 10)).action == .editing)
        #expect(editor.cursor == 4)
    }

    @Test("ASCII edits agree with an independent state machine")
    func asciiStateMachine() {
        var editor = ShellLineEditor()
        var reference: [UInt8] = []
        var referenceCursor = 0
        var sequence: UInt32 = 1
        var state: UInt32 = 0xC0FFEE
        for _ in 0..<2_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            switch state % 5 {
                case 0:
                    let byte = UInt8(ascii: "a") + UInt8(truncatingIfNeeded: state >> 24) % 26
                    _ = insertByte(byte, into: &editor, sequence: &sequence)
                    reference.insert(byte, at: referenceCursor)
                    referenceCursor += 1
                case 1:
                    _ = editor.apply(key(.left, sequence: sequence))
                    sequence += 1
                    if referenceCursor > 0 { referenceCursor -= 1 }
                case 2:
                    _ = editor.apply(key(.right, sequence: sequence))
                    sequence += 1
                    if referenceCursor < reference.count { referenceCursor += 1 }
                case 3:
                    _ = editor.apply(key(.backspace, sequence: sequence))
                    sequence += 1
                    if referenceCursor > 0 {
                        referenceCursor -= 1
                        reference.remove(at: referenceCursor)
                    }
                default:
                    _ = editor.apply(key(.delete, sequence: sequence))
                    sequence += 1
                    if referenceCursor < reference.count { reference.remove(at: referenceCursor) }
            }
            #expect(editor.cursor == referenceCursor)
            #expect(bytes(of: &editor) == reference)
        }
    }

    @Test("grapheme movement and deletion preserve deterministic clusters")
    func graphemeMovement() {
        let clusters = ["e\u{301}", "♥️", "👍🏽", "👩‍💻", "🇮🇹", "각", "界"]
        for cluster in clusters {
            var editor = ShellLineEditor()
            var sequence: UInt32 = 1
            insert(Array(cluster.utf8), into: &editor, sequence: &sequence)
            let end = editor.cursor
            _ = editor.apply(key(.left, sequence: sequence))
            let start = editor.cursor
            #expect(start == 0)
            _ = editor.apply(key(.right, sequence: sequence + 1))
            let restored = editor.cursor
            #expect(restored == end)
            _ = editor.apply(key(.backspace, sequence: sequence + 2))
            let empty = editor.count
            #expect(empty == 0)
        }
    }

    @Test("long wide-text cursor walks preserve overlapping gap bytes")
    func wideGapWalkPreservesUTF8() {
        var editor   = ShellLineEditor()
        let expected = Array(String(repeating: "界", count: 256).utf8)
        var sequence : UInt32 = 1
        var offset   = 0
        while offset < expected.count {
            let amount = min(15, expected.count - offset)
            expected.withUnsafeBufferPointer { source in
                _ = editor.apply(
                    ReixInputRecord(
                        kind: .insert,
                        sequence: sequence,
                        bytes: source.baseAddress!.advanced(by: offset),
                        count: amount
                    )!
                )
            }
            offset += amount
            sequence &+= 1
        }
        for _ in 0..<255 {
            #expect(editor.apply(key(.left, sequence: sequence)).requiresPresentation)
            sequence &+= 1
        }
        #expect(bytes(of: &editor) == expected)
        #expect(editor.cursor == 3)
    }

    @Test("selection replacement and undo redo are semantic operations")
    func selectionUndoRedo() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        insert(Array("a👩‍💻b".utf8), into: &editor, sequence: &sequence)
        _ = editor.apply(key(.left, sequence: sequence, modifiers: [.shift]))
        _ = editor.apply(key(.left, sequence: sequence + 1, modifiers: [.shift]))
        let selected = editor.hasSelection
        #expect(selected)
        _ = insertByte(0x78, into: &editor, sequence: &sequence)
        #expect(bytes(of: &editor) == Array("ax".utf8))
        _ = editor.apply(key(.undo, sequence: sequence, modifiers: [.control]))
        #expect(bytes(of: &editor) == Array("a👩‍💻b".utf8))
        _ = editor.apply(key(.redo, sequence: sequence + 1, modifiers: [.control]))
        #expect(bytes(of: &editor) == Array("ax".utf8))
    }

    @Test("paste publishes once and rolls back incompatible events")
    func atomicPaste() {
        var editor = ShellLineEditor()
        #expect(editor.withFrame { _ in true })
        _ = editor.apply(ReixInputRecord(kind: .pasteBegin, sequence: 1)!)
        let first = paste(Array("alpha".utf8), sequence: 2)
        let second = paste(Array("\nbeta".utf8), sequence: 3)
        #expect(!editor.apply(first).requiresPresentation)
        #expect(!editor.apply(second).requiresPresentation)
        let end = editor.apply(ReixInputRecord(kind: .pasteEnd, sequence: 4)!)
        #expect(end.requiresPresentation)
        #expect(editor.withFrame {
            $0.frame.kind == .snapshot
                && $0.frame.mode == .codeEditor
                && $0.frame.textLength == 10
        })
        _ = editor.apply(key(.undo, sequence: 5, modifiers: [.control]))
        let emptyAfterUndo = editor.count
        #expect(emptyAfterUndo == 0)

        _ = editor.apply(ReixInputRecord(kind: .pasteBegin, sequence: 6)!)
        _ = editor.apply(paste(Array("discard".utf8), sequence: 7))
        let reset = editor.apply(ReixInputRecord(kind: .focusLost, sequence: 8)!)
        #expect(reset.action == .refused)
        let emptyAfterRollback = editor.count
        #expect(emptyAfterRollback == 0)

        var sequence: UInt32 = 9
        insert(Array("redo".utf8), into: &editor, sequence: &sequence)
        _ = editor.apply(key(.undo, sequence: sequence, modifiers: [.control]))
        _ = editor.apply(ReixInputRecord(kind: .pasteBegin, sequence: sequence + 1)!)
        _ = editor.apply(paste(Array("temporary".utf8), sequence: sequence + 2))
        _ = editor.apply(ReixInputRecord(kind: .stateReset, sequence: sequence + 3)!)
        _ = editor.apply(key(.redo, sequence: sequence + 4, modifiers: [.control]))
        #expect(bytes(of: &editor) == Array("redo".utf8))
    }

    @Test("paste beyond 8192 bytes rolls the complete transaction back")
    func pasteOverflowRollsBack() {
        var editor   = ShellLineEditor()
        var sequence : UInt32 = 1
        insert(
            [UInt8](repeating: UInt8(ascii: "a"), count: ShellLineEditor.capacity - 8),
            into: &editor,
            sequence: &sequence
        )
        let before = bytes(of: &editor)
        let cursor = editor.cursor
        #expect(!editor.apply(ReixInputRecord(kind: .pasteBegin, sequence: sequence)!).requiresPresentation)
        sequence &+= 1
        let refused = editor.apply(
            paste([UInt8](repeating: UInt8(ascii: "z"), count: 16), sequence: sequence)
        )
        #expect(refused.action == .refused)
        #expect(bytes(of: &editor) == before)
        #expect(editor.cursor == cursor)
        let hasSelection = editor.hasSelection
        #expect(!hasSelection)
    }

    @Test("allocation faults leave storage journals history paste and scene coherent")
    func allocationFaults() {
        var sequence: UInt32 = 1

        var promotion = ShellLineEditor(
            allocationFault: ShellEditorAllocationFault(site: .storage)
        )
        insert(
            [UInt8](repeating: UInt8(ascii: "a"), count: ShellLineEditor.inlineCapacity),
            into: &promotion,
            sequence: &sequence
        )
        var emitted = false
        #expect(promotion.withFrame { _ in emitted = true; return true })
        #expect(emitted)
        let beforePromotion       = bytes(of: &promotion)
        let beforePromotionCursor = promotion.cursor
        let refusedPromotion      = insertByte(0x62, into: &promotion, sequence: &sequence)
        #expect(refusedPromotion.action == .refused)
        #expect(bytes(of: &promotion) == beforePromotion)
        #expect(promotion.cursor == beforePromotionCursor)
        emitted = false
        #expect(promotion.withFrame { _ in emitted = true; return true })
        #expect(!emitted)

        var laterGrowth = ShellLineEditor(
            allocationFault: ShellEditorAllocationFault(site: .storage, occurrence: 2)
        )
        insert([UInt8](repeating: 0x63, count: 1024), into: &laterGrowth, sequence: &sequence)
        let beforeGrowth = bytes(of: &laterGrowth)
        #expect(insertByte(0x64, into: &laterGrowth, sequence: &sequence).action == .refused)
        #expect(bytes(of: &laterGrowth) == beforeGrowth)

        var undo = ShellLineEditor(
            allocationFault: ShellEditorAllocationFault(site: .undo)
        )
        #expect(insertByte(0x75, into: &undo, sequence: &sequence).action == .editing)
        #expect(undo.apply(key(.undo, sequence: sequence, modifiers: [.control])).action == .refused)
        sequence += 1
        #expect(bytes(of: &undo) == [0x75])

        var history = ShellLineEditor(
            allocationFault: ShellEditorAllocationFault(site: .history)
        )
        insert(Array("history".utf8), into: &history, sequence: &sequence)
        #expect(history.apply(key(.enter, sequence: sequence, modifiers: [.control])).action == .submitted(7))
        sequence += 1
        history.reset()
        #expect(
            history.apply(shellTestKey(.historyPrevious, sequence: sequence)).action
                == .refused
        )
        sequence += 1
        #expect(history.count == 0)

        var backup = ShellLineEditor(
            allocationFault: ShellEditorAllocationFault(site: .pasteBackup)
        )
        insert(Array("abc".utf8), into: &backup, sequence: &sequence)
        for _ in 0..<2 {
            _ = backup.apply(key(.left, sequence: sequence, modifiers: [.shift]))
            sequence += 1
        }
        let beforeBackup                = bytes(of: &backup)
        let beforeBackupCursor          = backup.cursor
        let selectedBeforeBackupFailure = backup.hasSelection
        #expect(selectedBeforeBackupFailure)
        #expect(
            backup.apply(ReixInputRecord(kind: .pasteBegin, sequence: sequence)!).action
                == .refused
        )
        sequence += 1
        #expect(bytes(of: &backup) == beforeBackup)
        #expect(backup.cursor == beforeBackupCursor)
        let selectedAfterBackupFailure = backup.hasSelection
        #expect(selectedAfterBackupFailure)

        var pasteGrowth = ShellLineEditor(
            allocationFault: ShellEditorAllocationFault(site: .storage)
        )
        insert([UInt8](repeating: 0x70, count: 380), into: &pasteGrowth, sequence: &sequence)
        let beforePaste = bytes(of: &pasteGrowth)
        _ = pasteGrowth.apply(ReixInputRecord(kind: .pasteBegin, sequence: sequence)!)
        sequence += 1
        let pasteFailure = pasteGrowth.apply(
            paste([UInt8](repeating: 0x71, count: 16), sequence: sequence)
        )
        sequence += 1
        #expect(pasteFailure.action == .refused)
        #expect(bytes(of: &pasteGrowth) == beforePaste)
        #expect(pasteGrowth.cursor == beforePaste.count)
    }

    @Test("Shift Enter opens a script sheet and Tab inserts four spaces")
    func multilineViewportAndStyles() {
        var editor   = ShellLineEditor()
        var sequence : UInt32 = 1
        _ = editor.apply(ReixInputRecord(kind: .resize, sequence: sequence, width: 40, height: 12)!)
        sequence += 1
        let opened = editor.apply(key(.enter, sequence: sequence, modifiers: [.shift]))
        sequence += 1
        #expect(opened.action == .editing)
        let openedCodeEditor = editor.isCodeEditing
        #expect(openedCodeEditor)
        #expect(editor.count == 0)
        #expect(editor.withFrame {
            $0.frame.mode == .codeEditor
                && $0.frame.textLength == 0
                && $0.frame.cursorRow == 1
                && $0.frame.cursorColumn == ReixCodeEditorLayout.standardGutterColumns
                && $0.frame.viewportRows == 3
                && $0.styleCount == 0
        })

        let tab = editor.apply(key(.tab, sequence: sequence))
        sequence += 1
        #expect(tab.action == .editing)
        #expect(bytes(of: &editor) == [0x20, 0x20, 0x20, 0x20])

        insert(Array("shell.help()".utf8), into: &editor, sequence: &sequence)
        let newline = editor.apply(key(.enter, sequence: sequence))
        sequence += 1
        #expect(newline.action == .editing)
        #expect(bytes(of: &editor).last == 0x0A)
        #expect(editor.withFrame {
            $0.frame.mode == .codeEditor
                && $0.frame.viewportRows == 3
                && $0.styleCount == 1
                && $0.styles?[0].offset == 0
        })

        let submit = editor.apply(key(.enter, sequence: sequence, modifiers: [.control]))
        #expect(submit.action == .submitted(editor.count))
        sequence += 1
        editor.reset()
        let resetCodeEditor = editor.isCodeEditing
        #expect(!resetCodeEditor)

        _ = editor.apply(key(.enter, sequence: sequence, modifiers: [.shift]))
        sequence += 1
        let historyBefore = bytes(of: &editor)
        let upAtTop       = editor.apply(key(.up, sequence: sequence))
        #expect(upAtTop.action == .editing)
        #expect(bytes(of: &editor) == historyBefore)
        let stillCodeEditing = editor.isCodeEditing
        #expect(stillCodeEditing)
    }

    @Test("editor viewport grows and shrinks with wrapped content")
    func dynamicViewportRows() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        _ = editor.apply(ReixInputRecord(kind: .resize, sequence: sequence, width: 10, height: 8)!)
        sequence += 1
        #expect(editor.withFrame { $0.frame.viewportRows == 1 })

        insert(Array("abcd".utf8), into: &editor, sequence: &sequence)
        #expect(editor.withFrame { $0.frame.viewportRows == 2 })

        _ = editor.apply(key(.backspace, sequence: sequence))
        #expect(editor.withFrame {
            $0.frame.viewportRows == 1
                && $0.frame.viewportRow == 0
        })
    }

    @Test("Unicode profile reports cells for combining CJK and emoji")
    func unicodeCells() {
        #expect(ReixTextLayout.unicodeMajor == 16)
        #expect(ReixTextLayout.unicodeMinor == 0)
        checkWidth("\u{301}", 1)
        checkWidth("e\u{301}", 1)
        checkWidth("界", 2)
        checkWidth("♥️", 2)
        checkWidth("👍🏽", 2)
        checkWidth("👩‍💻", 2)
        checkWidth("🇮🇹", 2)
    }

    @Test("undo and history evict complete bounded records")
    func boundedJournals() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        for _ in 0..<40 { _ = insertByte(0x61, into: &editor, sequence: &sequence) }
        for _ in 0..<ShellLineEditor.undoCapacity {
            #expect(editor.apply(key(.undo, sequence: sequence, modifiers: [.control])).action == .editing)
            sequence += 1
        }
        #expect(editor.count == 8)
        #expect(editor.apply(key(.undo, sequence: sequence, modifiers: [.control])).action == .refused)

        editor.reset()
        for marker in 0..<5 {
            insert(
                [UInt8](repeating: UInt8(ascii: "a") + UInt8(marker), count: 1024),
                into: &editor,
                sequence: &sequence
            )
            #expect(editor.apply(key(.enter, sequence: sequence, modifiers: [.control])).action == .submitted(1024))
            sequence += 1
            editor.reset()
        }
        for marker in stride(from: 4, through: 1, by: -1) {
            let update = editor.apply(shellTestKey(.historyPrevious, sequence: sequence))
            sequence += 1
            #expect(update.action == .editing)
            #expect(bytes(of: &editor).first == UInt8(ascii: "a") + UInt8(marker))
        }
        #expect(editor.apply(shellTestKey(.historyPrevious, sequence: sequence)).action == .refused)
    }

    @Test("maximum input stays segmented and resize forces a native snapshot")
    func maximumSegmentedSnapshot() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        insert([UInt8](repeating: 0x61, count: ShellLineEditor.capacity), into: &editor, sequence: &sequence)
        _ = editor.apply(ReixInputRecord(kind: .resize, sequence: sequence, width: 80, height: 24)!)
        #expect(editor.withFrame {
            $0.frame.kind == .snapshot
                && $0.frame.textLength == UInt32(ReixTextSurfaceFrameDescriptor.maximumTextBytes)
                && $0.text0Length == 8
                && $0.text1Length + $0.text2Length == ShellLineEditor.capacity
        })
    }

    @Test("page movement keeps the cursor inside the bounded scrolling viewport")
    func pageMovement() {
        var editor = ShellLineEditor()
        var sequence: UInt32 = 1
        _ = editor.apply(ReixInputRecord(kind: .resize, sequence: sequence, width: 10, height: 8)!)
        sequence += 1
        for line in 0..<8 {
            _ = insertByte(0x61, into: &editor, sequence: &sequence)
            if line < 7 {
                _ = editor.apply(key(.enter, sequence: sequence, modifiers: [.shift]))
                sequence += 1
            }
        }
        var beforeRow: UInt16 = 0
        var beforeViewport: UInt16 = 0
        #expect(editor.withFrame {
            beforeRow = $0.frame.cursorRow
            beforeViewport = $0.frame.viewportRow
            return true
        })
        #expect(editor.apply(key(.pageUp, sequence: sequence)).action == .editing)
        #expect(editor.withFrame {
            $0.frame.cursorRow < beforeRow
                && $0.frame.viewportRow < beforeViewport
                && $0.frame.cursorRow >= $0.frame.viewportRow
                && $0.frame.cursorRow - $0.frame.viewportRow < $0.frame.viewportRows
        })
    }

    private func checkWidth(_ text: String, _ expected: UInt16) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let width = ReixTextLayout.cellWidth(
                from: 0,
                to: buffer.count,
                count: buffer.count,
                byte: { buffer[$0] }
            )
            #expect(width == expected, "unexpected width for \(text)")
        }
    }
}

private func key(
    _ key: ReixInputKey,
    sequence: UInt32,
    modifiers: ReixInputModifiers = []
) -> ReixInputRecord {
    ReixInputRecord(
        kind: .key,
        modifiers: modifiers,
        sequence: sequence,
        logicalKey: key,
        physicalKey: 0x8000 | key.rawValue
    )!
}

private func paste(_ bytes: [UInt8], sequence: UInt32) -> ReixInputRecord {
    bytes.withUnsafeBufferPointer {
        ReixInputRecord(
            kind: .pasteChunk,
            sequence: sequence,
            bytes: $0.baseAddress,
            count: $0.count
        )!
    }
}

@discardableResult
private func insertByte(
    _ byte: UInt8,
    into editor: inout ShellLineEditor,
    sequence: inout UInt32
) -> ShellEditorUpdate {
    var value = byte
    let result = withUnsafePointer(to: &value) {
        editor.apply(
            ReixInputRecord(kind: .insert, sequence: sequence, bytes: $0, count: 1)!
        )
    }
    sequence += 1
    return result
}

private func insert(
    _ bytes: [UInt8],
    into editor: inout ShellLineEditor,
    sequence: inout UInt32
) {
    var offset = 0
    while offset < bytes.count {
        let amount = min(16, bytes.count - offset)
        bytes.withUnsafeBufferPointer {
            _ = editor.apply(
                ReixInputRecord(
                    kind: .insert,
                    sequence: sequence,
                    bytes: $0.baseAddress!.advanced(by: offset),
                    count: amount
                )!
            )
        }
        sequence += 1
        offset += amount
    }
}

private func bytes(of editor: inout ShellLineEditor) -> [UInt8] {
    editor.withBytes { Array(UnsafeBufferPointer(start: $0, count: $1)) }
}
