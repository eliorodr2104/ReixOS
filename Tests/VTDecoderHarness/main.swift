//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

private func require(_ condition: Bool) {
    if !condition {
        fatalError("VTDecoder harness failure")
    }
}

private func records(
    _ bytes: [UInt8],
    split: Int
) -> [ReixInputRecord] {
    var decoder = VTDecoder()
    var output: [ReixInputRecord] = []
    for chunk in [Array(bytes.prefix(split)), Array(bytes.dropFirst(split))] {
        chunk.withUnsafeBufferPointer { pointer in
            var offset = 0
            while offset < chunk.count {
                offset += decoder.consume(
                    pointer.baseAddress!.advanced(by: offset),
                    count: chunk.count - offset
                )
                while let record = decoder.pop() { output.append(record) }
            }
        }
    }
    while let record = decoder.pop() { output.append(record) }
    return output
}

private func payload(_ records: ArraySlice<ReixInputRecord>) -> [UInt8] {
    var bytes: [UInt8] = []
    for record in records {
        for index in 0..<record.count { bytes.append(record.text[index]) }
    }
    return bytes
}

private func testSplitSequences() {
    let sequences: [[UInt8]] = [
        [0x1B, 0x5B, 0x41],
        [0x1B, 0x5B, 0x42],
        [0x1B, 0x5B, 0x43],
        [0x1B, 0x5B, 0x44],
        [0x1B, 0x5B, 0x48],
        [0x1B, 0x5B, 0x31, 0x7E],
        [0x1B, 0x5B, 0x46],
        [0x1B, 0x5B, 0x34, 0x7E],
        [0x1B, 0x5B, 0x33, 0x7E],
        [0x1B, 0x5B, 0x35, 0x7E],
        [0x1B, 0x5B, 0x36, 0x7E],
        [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x44],
        [0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75],
        [0x1B, 0x5B, 0x31, 0x32, 0x32, 0x3B, 0x36, 0x75]
    ]
    for sequence in sequences {
        for split in 0...sequence.count {
            let output = records(sequence, split: split)
            require(output.count == 1)
            require(output[0].kind == .key)
            require(output[0].physicalKey & 0x8000 != 0)
        }
    }
    for split in 0...2 {
        let output = records([0x1B, 0x78], split: split)
        require(output.count == 2)
        require(output[0].logicalKey == .escape)
    }
    require(records([0x09], split: 0)[0].logicalKey == .tab)
    let shiftedLeft = records([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x44], split: 3)[0]
    require(shiftedLeft.logicalKey == .left)
    require(shiftedLeft.modifiers == [.shift])
    let shiftedEnter = records([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75], split: 4)[0]
    require(shiftedEnter.logicalKey == .enter)
    require(shiftedEnter.modifiers == [.shift])
    let redo = records([0x1B, 0x5B, 0x31, 0x32, 0x32, 0x3B, 0x36, 0x75], split: 4)[0]
    require(redo.logicalKey == .redo)
    require(redo.modifiers == [.shift, .control])
    require(records([0x1A], split: 0)[0].logicalKey == .undo)
    require(records([0x19], split: 0)[0].logicalKey == .redo)
    let malformedCSI: [[UInt8]] = [
        [0x1B, 0x5B, 0x32, 0x3B, 0x32, 0x44],
        [0x1B, 0x5B, 0x31, 0x3B, 0x39, 0x44],
        [0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x39, 0x75]
    ]
    for malformed in malformedCSI {
        let output = records(malformed, split: 3)
        require(output.count == 1)
        require(output[0].logicalKey == .escape)
    }
    let controls = records([0x03, 0x04, 0x08, 0x7F], split: 2)
    require(controls[0].kind == .cancel)
    require(controls[1].kind == .eof)
    require(controls[2].logicalKey == .backspace)
    require(controls[3].logicalKey == .backspace)
    require(records([0x00], split: 0)[0].kind == .ignored)
}

private func testTextAndPaste() {
    for split in 0...2 {
        let output = records([0x0D, 0x0A], split: split)
        require(output.count == 1)
        require(output[0].kind == .enter)
    }
    let valid = [UInt8]("A€".utf8)
    for split in 0...valid.count {
        let output = records(valid, split: split)
        require(output.count == 2)
    }
    let malformed: [UInt8] = [0xE0, 0x80, 0x41]
    for split in 0...malformed.count {
        let output = records(malformed, split: split)
        require(output.count == 3)
    }
    for malformed in [[UInt8](repeating: 0x80, count: 1), [0xC0], [0xED, 0xA0], [0xF4, 0x90]] {
        for split in 0...malformed.count {
            let output = records(malformed, split: split)
            require(output.allSatisfy { $0.kind == .insert })
        }
    }
    let paste: [UInt8] = [
        0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
        0x61, 0x0A, 0x62,
        0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E
    ]
    for split in 0...paste.count {
        let output = records(paste, split: split)
        require(output.first?.kind == .pasteBegin)
        require(output.last?.kind == .pasteEnd)
        require(output.dropFirst().dropLast().allSatisfy { $0.kind == .pasteChunk })
    }
    let utf8Paste: [UInt8] = [
        0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
        0xE2, 0x82, 0xAC,
        0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E
    ]
    for split in 0...utf8Paste.count {
        let output = records(utf8Paste, split: split)
        require(output[0].kind == .pasteBegin)
        require(output[1].kind == .pasteChunk)
        require(payload(output[1...1]) == [0xE2, 0x82, 0xAC])
        require(output[2].kind == .pasteEnd)
    }
}

private func testPasteMismatchAndReset() {
    let bytes: [UInt8] = [
        0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
        0x1B, 0x5B, 0x32, 0x30, 0x32, 0x7E
    ]
    let output = records(bytes, split: 8)
    require(output[0].kind == .pasteBegin)
    require(output.dropFirst().allSatisfy { $0.kind == .pasteChunk })
    require(
        payload(output.dropFirst()) == [
            0xEF, 0xBF, 0xBD,
            0x5B, 0x32, 0x30, 0x32, 0x7E
        ]
    )
    var decoder = VTDecoder()
    let incomplete: [UInt8] = [0xE2, 0x82]
    incomplete.withUnsafeBufferPointer {
        require(decoder.consume($0.baseAddress!, count: incomplete.count) == incomplete.count)
    }
    require(decoder.reset())
    require(decoder.pop()?.kind == .insert)
    require(decoder.pop()?.kind == .stateReset)
}

private func testPasteSanitization() {
    let bytes: [UInt8] = [
        0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
        0x0D, 0x0A, 0x09,
        0x1B, 0x5B, 0x32, 0x30, 0x31, 0x78,
        0x7F, 0x9B,
        0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E
    ]
    let output = records(bytes, split: 11)
    var editor = ShellLineEditor()
    var update: ShellEditorUpdate?
    for record in output { update = editor.apply(record) }
    let expected: [UInt8] = [
        0x0A,
        0x20, 0x20, 0x20, 0x20,
        0xEF, 0xBF, 0xBD,
        0x5B, 0x32, 0x30, 0x31, 0x78,
        0xEF, 0xBF, 0xBD,
        0xEF, 0xBF, 0xBD
    ]
    var line = InlineArray<256, UInt8>(repeating: 0)
    let count = editor.copyLine(into: &line)
    require(count == expected.count)
    for index in 0..<count { require(line[index] == expected[index]) }
    require(update?.requiresPresentation == true)

    let c1Paste: [UInt8] = [
        0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E,
        0xC2, 0x80,
        0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E
    ]
    var decoder = VTDecoder()
    c1Paste.withUnsafeBufferPointer {
        require(decoder.consume($0.baseAddress!, count: c1Paste.count) == c1Paste.count)
    }
    var c1Editor = ShellLineEditor()
    var c1Update: ShellEditorUpdate?
    while let record = decoder.pop() { c1Update = c1Editor.apply(record) }
    var c1Line = InlineArray<256, UInt8>(repeating: 0)
    require(c1Editor.copyLine(into: &c1Line) == 3)
    require(c1Line[0] == 0xEF)
    require(c1Line[1] == 0xBF)
    require(c1Line[2] == 0xBD)
    require(c1Update?.requiresPresentation == true)
}

private func testQueueResume() {
    var decoder = VTDecoder()
    let bytes = Array(repeating: UInt8(0x61), count: VTDecoder.queueCapacity + 1)
    let consumed = bytes.withUnsafeBufferPointer {
        decoder.consume($0.baseAddress!, count: bytes.count)
    }
    require(consumed == VTDecoder.queueCapacity)
    while decoder.pop() != nil {}
    let resumed = bytes.withUnsafeBufferPointer {
        decoder.consume($0.baseAddress!.advanced(by: consumed), count: bytes.count - consumed)
    }
    require(resumed == 1)

    var exact = VTDecoder()
    let full = Array(repeating: UInt8(0x61), count: VTDecoder.queueCapacity)
    full.withUnsafeBufferPointer {
        require(exact.consume($0.baseAddress!, count: full.count) == full.count)
    }
    let tail: [UInt8] = [0x62]
    tail.withUnsafeBufferPointer {
        require(exact.consume($0.baseAddress!, count: tail.count) == 0)
    }
    var output: [ReixInputRecord] = []
    output.append(exact.pop()!)
    tail.withUnsafeBufferPointer {
        require(exact.consume($0.baseAddress!, count: tail.count) == 1)
    }
    while let record = exact.pop() { output.append(record) }
    require(payload(output[...]) == full + tail)
}

private func testFinishIdle() {
    var decoder = VTDecoder()
    let escape: [UInt8] = [0x1B]
    escape.withUnsafeBufferPointer {
        require(decoder.consume($0.baseAddress!, count: escape.count) == 1)
    }
    require(decoder.finishIdle())
    require(decoder.pop()?.logicalKey == .escape)
    let bytes = Array(repeating: UInt8(0x61), count: VTDecoder.queueCapacity)
    bytes.withUnsafeBufferPointer {
        require(decoder.consume($0.baseAddress!, count: bytes.count) == bytes.count)
    }
    escape.withUnsafeBufferPointer {
        require(decoder.consume($0.baseAddress!, count: escape.count) == 1)
    }
    require(!decoder.finishIdle())
    while decoder.pop() != nil {}
    require(decoder.finishIdle())
    require(decoder.pop()?.logicalKey == .escape)
}

private func input(
    _ kind: ReixInputKind,
    sequence: UInt32,
    bytes: [UInt8] = []
) -> ReixInputRecord {
    bytes.withUnsafeBufferPointer {
        ReixInputRecord(
            kind: kind,
            sequence: sequence,
            bytes: $0.baseAddress,
            count: bytes.count
        )!
    }
}

private func testEditorPaste() {
    var editor = ShellLineEditor()
    _ = editor.apply(input(.insert, sequence: 1, bytes: [0x78]))
    _ = editor.apply(input(.pasteBegin, sequence: 2))
    _ = editor.apply(input(.pasteChunk, sequence: 3, bytes: [0x61, 0x0A, 0x62]))
    let commit = editor.apply(input(.pasteEnd, sequence: 4))
    require(commit.action == .editing)
    require(editor.count == 4)
    let enter = editor.apply(input(.enter, sequence: 5))
    require(enter.action == .submitted(4))
    _ = editor.apply(input(.pasteBegin, sequence: 6))
    for offset in 0..<511 {
        _ = editor.apply(
            input(
                .pasteChunk,
                sequence: UInt32(7 + offset),
                bytes: Array(repeating: 0x61, count: 16)
            )
        )
    }
    _ = editor.apply(
        input(.pasteChunk, sequence: 518, bytes: Array(repeating: 0x61, count: 12))
    )
    _ = editor.apply(input(.pasteChunk, sequence: 519, bytes: [0x61]))
    require(editor.count == 4)
}

private func testEditorControls() {
    var editor = ShellLineEditor()
    _ = editor.apply(input(.insert, sequence: 1, bytes: [0x61, 0x62]))
    let left = ReixInputRecord(
        kind: .key,
        sequence: 2,
        logicalKey: .left,
        physicalKey: 0x8001
    )!
    _ = editor.apply(left)
    let repeatLeft = ReixInputRecord(
        kind: .key,
        sequence: 3,
        logicalKey: .left,
        physicalKey: 0x8001,
        phase: .repeatKey,
        repeatCount: 1
    )!
    _ = editor.apply(repeatLeft)
    let release = ReixInputRecord(
        kind: .key,
        sequence: 5,
        logicalKey: .right,
        physicalKey: 0x8002,
        phase: .release
    )!
    _ = editor.apply(release)
    require(editor.cursor == 0)
    var destructive = ShellLineEditor()
    _ = destructive.apply(input(.insert, sequence: 6, bytes: [0x61, 0x62, 0x63, 0x64]))
    let repeatedBackspace = ReixInputRecord(
        kind: .key,
        sequence: 7,
        logicalKey: .backspace,
        physicalKey: 0x8007,
        phase: .repeatKey,
        repeatCount: 2
    )!
    _ = destructive.apply(repeatedBackspace)
    require(destructive.count == 2)
    let excessiveBackspace = ReixInputRecord(
        kind: .key,
        sequence: 8,
        logicalKey: .backspace,
        physicalKey: 0x8007,
        phase: .repeatKey,
        repeatCount: 3
    )!
    let excessiveUpdate = destructive.apply(excessiveBackspace)
    require(excessiveUpdate.action == .refused)
    require(destructive.count == 2)
    require(destructive.cursor == 2)
    _ = editor.apply(input(.insert, sequence: 6, bytes: [0x61, 0x62]))
    _ = editor.apply(input(.pasteBegin, sequence: 7))
    _ = editor.apply(input(.pasteChunk, sequence: 8, bytes: [0x63]))
    let pasteRepeat = ReixInputRecord(
        kind: .key,
        sequence: 9,
        logicalKey: .left,
        physicalKey: 0x8001,
        phase: .repeatKey,
        repeatCount: 1
    )!
    _ = editor.apply(pasteRepeat)
    require(editor.count == 4)
    _ = editor.apply(input(.pasteBegin, sequence: 9))
    require(editor.count == 4)
    _ = editor.apply(input(.pasteBegin, sequence: 10))
    _ = editor.apply(input(.pasteChunk, sequence: 11, bytes: [0x64]))
    _ = editor.apply(input(.focusLost, sequence: 12))
    require(editor.count == 4)
}

testSplitSequences()
testTextAndPaste()
testPasteMismatchAndReset()
testPasteSanitization()
testQueueResume()
testFinishIdle()
testEditorPaste()
testEditorControls()
