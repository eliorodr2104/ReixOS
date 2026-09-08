//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import KernelHostShims
import Reix
import ReixABI
import TerminalTestSupport

private var checks = 0
private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: StaticString) {
    checks += 1
    if !condition() {
        failures += 1
        print("TextSurfaceRingHarness failure: \(message)")
    }
}

private func cursor(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int) -> UnsafeMutablePointer<UInt32> {
    UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self)
}

private func feed(_ bytes: [UInt8], into screen: inout TerminalScreenModel) -> Bool {
    do {
        try screen.feed(bytes)
        try screen.finish()
        return true
    } catch {
        return false
    }
}

/// Whether every colour change starts by resetting.
///
/// Roles are additive: `selection` is reverse video and `command` is a
/// foreground, so a switch that does not reset first leaves the reverse
/// running under everything after it. That is what painted the rows below a
/// selected row, and beyond the box they were in.
private func everyStyleResets(_ bytes: [UInt8]) -> Bool {
    var index = 0
    while index + 1 < bytes.count {
        guard bytes[index] == 0x1B, bytes[index + 1] == UInt8(ascii: "[") else {
            index += 1
            continue
        }
        var end = index + 2
        while end < bytes.count, bytes[end] != UInt8(ascii: "m"),
              bytes[end] >= 0x30, bytes[end] <= 0x3F {
            end += 1
        }
        guard end < bytes.count, bytes[end] == UInt8(ascii: "m") else {
            index += 1
            continue
        }
        guard bytes[index + 2] == UInt8(ascii: "0") else { return false }
        index = end + 1
    }
    return true
}

private func occurrences(
    of needle: [UInt8],
    in bytes : [UInt8]
) -> Int {
    guard !needle.isEmpty, needle.count <= bytes.count else { return 0 }
    var count = 0
    for start in 0...(bytes.count - needle.count) {
        var matches = true
        for index in 0..<needle.count where bytes[start + index] != needle[index] {
            matches = false
            break
        }
        if matches { count += 1 }
    }
    return count
}

private func descriptor(
    kind          : ReixTextSurfaceFrameKind = .snapshot,
    mode          : ReixTextSurfaceFrameMode = .editor,
    source        : UInt32 = 0,
    severity      : ReixTextOutputSeverity = .info,
    outputKind    : ReixTextOutputKind = .application,
    payloadKind   : ReixTextOutputPayloadKind = .utf8Text,
    correlation   : UInt32 = 1,
    revision      : UInt32 = 1,
    baseRevision  : UInt32 = 0,
    patchOffset   : UInt32 = 0,
    replacedLength: UInt32 = 0,
    textLength    : Int,
    overlayLength : Int = 0,
    styles        : Int = 0,
    overlayStyles : Int = 0,
    columns       : UInt16 = 80,
    rows          : UInt16 = 24,
    cursorRow     : UInt16 = 0,
    cursorColumn  : UInt16 = 0,
    viewportRow   : UInt16 = 0,
    viewportRows  : UInt16 = 6,
    overlayRows   : UInt16 = 0,
    overlayColumns: UInt16 = 0
) -> ReixTextSurfaceFrameDescriptor {
    ReixTextSurfaceFrameDescriptor(
        kind: kind,
        mode: mode,
        source: source,
        severity: severity,
        outputKind: outputKind,
        payloadKind: payloadKind,
        correlation: correlation,
        revision: revision,
        baseRevision: baseRevision,
        patchOffset: patchOffset,
        replacedLength: replacedLength,
        textLength: UInt32(textLength),
        overlayLength: UInt16(overlayLength),
        styleSpanCount: UInt16(styles),
        overlayStyleSpanCount: UInt16(overlayStyles),
        columns: columns,
        rows: rows,
        cursorRow: cursorRow,
        cursorColumn: cursorColumn,
        viewportRow: viewportRow,
        viewportRows: viewportRows,
        overlayRows: UInt16(overlayRows),
        overlayColumns: UInt16(overlayColumns)
    )!
}

private func push(
    _ ring: ReixTextSurfaceRing,
    transaction: UInt32,
    descriptor: ReixTextSurfaceFrameDescriptor,
    text: [UInt8],
    styles: [ReixTextSurfaceStyleSpan] = [],
    overlay: [UInt8] = [],
    overlayStyles: [ReixTextSurfaceStyleSpan] = []
) -> Bool {
    text.withUnsafeBufferPointer { textBytes in
        styles.withUnsafeBufferPointer { styleBytes in
            overlay.withUnsafeBufferPointer { overlayBytes in
                overlayStyles.withUnsafeBufferPointer { overlayStyleBytes in
                    guard let frame = ReixTextSurfaceFrameSource(
                        descriptor: descriptor,
                        text: text.isEmpty ? nil : textBytes.baseAddress!,
                        styles: styles.isEmpty ? nil : styleBytes.baseAddress!,
                        overlay: overlay.isEmpty ? nil : overlayBytes.baseAddress!,
                        overlayStyles: overlayStyles.isEmpty ? nil : overlayStyleBytes.baseAddress!
                    ) else { return false }
                    return ring.push(transaction: transaction, frame: frame)
                }
            }
        }
    }
}

kernel_host_shims_link_anchor()
let page = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTextSurfaceTransport.regionBytes)
defer { page.deallocate() }
for index in 0..<ReixTextSurfaceTransport.regionBytes { page[index] = 0xA5 }

check(ReixTextSurfaceTransport.pages == 3, "minimum three-page region")
check(
    ReixTextSurfaceTransport.capacity
        == (ReixTextSurfaceTransport.regionBytes - ReixTextSurfaceTransport.headerBytes)
            / ReixTextSurfaceProtocol.recordBytes,
    "capacity derives from the region"
)
check(
    ReixTextSurfaceTransport.maximumFrameRecords <= ReixTextSurfaceTransport.capacity,
    "largest snapshot is atomic"
)
check(
    ReixTextSurfaceTransport.maximumFrameRecords
        > (2 * ReixTextSurfaceTransport.pageBytes - ReixTextSurfaceTransport.headerBytes)
            / ReixTextSurfaceProtocol.recordBytes,
    "two pages cannot hold the largest snapshot"
)
check(ReixTextSurfaceRing.initialize(page: page, token: 7), "proposal")
check(page[ReixTextSurfaceTransport.regionBytes - 1] == 0, "initialization clears every page")
check(ReixTextSurfaceRing.accept(page: page, token: 7, epoch: 9), "accept")
var producer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
var consumer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
check(consumer.popFrame(transaction: 1) { _ in .commit } == .empty, "empty typed result")

let greeting = Array("reix❯ vault".utf8)
let greetingDescriptor = descriptor(
    source: 7,
    severity: .notice,
    outputKind: .status,
    payloadKind: .utf8KeyValue,
    textLength: greeting.count,
    cursorColumn: UInt16(greeting.count)
)
check(push(producer, transaction: 1, descriptor: greetingDescriptor, text: greeting), "snapshot push")
var decodedGreeting = [UInt8]()
check(
    consumer.popFrame(transaction: 1) { frame in
        for index in 0..<Int(frame.descriptor.textLength) { decodedGreeting.append(frame.textByte(at: index)!) }
        return .commit
    } == .committed,
    "snapshot pop"
)
check(decodedGreeting == greeting, "snapshot roundtrip")
check(greetingDescriptor.mode == .editor, "frame mode roundtrip")
check(greetingDescriptor.source == 7, "frame source roundtrip")
check(greetingDescriptor.severity == .notice, "frame severity roundtrip")
check(greetingDescriptor.outputKind == .status, "frame output kind roundtrip")
check(greetingDescriptor.payloadKind == .utf8KeyValue, "frame payload kind roundtrip")

let maximumText = [UInt8](
    repeating: UInt8(ascii: "x"),
    count: ReixTextSurfaceFrameDescriptor.maximumTextBytes
)
let maximumStyles = (0..<32).map {
    ReixTextSurfaceStyleSpan(offset: UInt32($0), length: 1, role: .input)!
}
let maximumOverlay = [UInt8](repeating: UInt8(ascii: "o"), count: 1024)
let maximumOverlayStyles = (0..<16).map {
    ReixTextSurfaceStyleSpan(offset: UInt32($0), length: 1, role: .overlay)!
}
let maximumDescriptor = descriptor(
    correlation: 2,
    revision: 2,
    textLength: maximumText.count,
    overlayLength: maximumOverlay.count,
    styles: maximumStyles.count,
    overlayStyles: maximumOverlayStyles.count,
    columns: 240,
    rows: 120,
    cursorRow: 34,
    cursorColumn: 32,
    viewportRow: 20,
    viewportRows: 15,
    overlayRows: 15,
    overlayColumns: 240
)
check(
    push(
        producer,
        transaction: 2,
        descriptor: maximumDescriptor,
        text: maximumText,
        styles: maximumStyles,
        overlay: maximumOverlay,
        overlayStyles: maximumOverlayStyles
    ),
    "maximum snapshot push"
)
check(
    !push(producer, transaction: 3, descriptor: greetingDescriptor, text: greeting),
    "backpressure preserves unread transaction"
)
check(
    consumer.popFrame(transaction: 2) { frame in
        check(
            frame.textByte(at: ReixTextSurfaceFrameDescriptor.maximumTextBytes - 1) == UInt8(ascii: "x"),
            "maximum text boundary"
        )
        check(frame.overlayByte(at: 1023) == UInt8(ascii: "o"), "maximum overlay boundary")
        check(frame.styleSpan(at: 31)?.role == .input, "maximum style boundary")
        return .commit
    } == .committed,
    "maximum snapshot pop"
)

let savedProducer = cursor(page, 28).pointee
check(push(producer, transaction: 4, descriptor: greetingDescriptor, text: greeting), "partial setup")
cursor(page, 28).pointee = savedProducer + 1
check(consumer.popFrame(transaction: 4) { _ in .commit } == .incomplete, "partial batch is distinct")
cursor(page, 28).pointee = savedProducer + UInt32(
    2 + (greeting.count + ReixTextSurfaceFrameRecord.payloadBytes - 1)
        / ReixTextSurfaceFrameRecord.payloadBytes
)
check(consumer.popFrame(transaction: 5) { _ in .commit } == .stale, "stale transaction is distinct")
check(consumer.popFrame(transaction: 4) { _ in .retry } == .retry, "retry does not consume")
check(consumer.popFrame(transaction: 4) { _ in .commit } == .committed, "retry can commit later")

check(push(producer, transaction: 5, descriptor: greetingDescriptor, text: greeting), "corruption setup")
let consumerCursor = cursor(page, 32).pointee
let chunkSlot = Int((consumerCursor + 1) % UInt32(ReixTextSurfaceTransport.capacity))
let payloadAddress = ReixTextSurfaceTransport.headerBytes
    + chunkSlot * ReixTextSurfaceProtocol.recordBytes
    + ReixTextSurfaceProtocol.headerBytes
page[payloadAddress] ^= 0x01
check(consumer.popFrame(transaction: 5) { _ in .commit } == .malformed, "checksum corruption")
check(cursor(page, 32).pointee == consumerCursor, "malformed batch remains until recovery")
check(consumer.recoverMalformed(), "explicit recovery")
check(cursor(page, 32).pointee == cursor(page, 28).pointee, "recovery resynchronizes cursors")

let escape = [UInt8](arrayLiteral: 0x1B, UInt8(ascii: "["), UInt8(ascii: "J"))
let escapeDescriptor = descriptor(correlation: 6, revision: 3, textLength: escape.count, cursorColumn: 3)
check(push(producer, transaction: 6, descriptor: escapeDescriptor, text: escape), "escape setup")
check(consumer.popFrame(transaction: 6) { _ in .commit } == .malformed, "escape is inert protocol data")
check(consumer.recoverMalformed(), "escape recovery")

let unicode = Array("reix λ vault".utf8)
let unicodeDescriptor = descriptor(
    correlation: 7,
    revision: 3,
    textLength: unicode.count,
    cursorColumn: 12
)
check(push(producer, transaction: 7, descriptor: unicodeDescriptor, text: unicode), "unicode setup")
check(consumer.popFrame(transaction: 7) { _ in .commit } == .committed, "unicode is one semantic stream")

cursor(page, 28).pointee = UInt32.max - 1
cursor(page, 32).pointee = UInt32.max - 1
producer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
consumer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
check(push(producer, transaction: 8, descriptor: greetingDescriptor, text: greeting), "cursor wrap push")
check(consumer.popFrame(transaction: 8) { _ in .commit } == .committed, "cursor wrap pop")
check(cursor(page, 28).pointee == cursor(page, 32).pointee, "cursor wrap remains coherent")

let acknowledgement = ReixTextSurfaceAcknowledgement(
    status: .committed,
    transaction: 8,
    revision: 1,
    baseRevision: 0,
    token: 7,
    epoch: 9
)!
check(producer.publish(acknowledgement), "ack publication")
check(producer.acknowledgement(transaction: 8) == acknowledgement, "ack binds every revision domain")
check(producer.acknowledgement(transaction: 9) == nil, "stale ack refused")
let preRevisionFailure = ReixTextSurfaceAcknowledgement(
    status: .malformed,
    transaction: 9,
    revision: 0,
    baseRevision: 0,
    token: 7,
    epoch: 9
)!
check(producer.publish(preRevisionFailure), "pre-revision failure ack publication")
check(producer.acknowledgement(transaction: 9) == preRevisionFailure, "zero revision failure ack is exact")

check(ReixTextSurfaceRing.initialize(page: page, token: 21), "screen model proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 21, epoch: 22), "screen model accept")
producer = ReixTextSurfaceRing(page: page, token: 21, epoch: 22)!
consumer = ReixTextSurfaceRing(page: page, token: 21, epoch: 22)!
var model = TextSurfaceScreenModel()
let abc = Array("abc".utf8)
let abcDescriptor = descriptor(revision: 1, textLength: abc.count, cursorColumn: 3)
check(push(producer, transaction: 1, descriptor: abcDescriptor, text: abc), "model snapshot setup")
check(
    consumer.popFrame(transaction: 1) { frame in
        check(model.prepare(frame) == .ready, "model snapshot ready")
        check(model.commit(frame), "model snapshot commit")
        return .commit
    } == .committed,
    "model snapshot consumed"
)
check(model.textLength == 3 && model.textByte(at: 1) == UInt8(ascii: "b"), "model stores UTF-8 bytes")

check(push(producer, transaction: 2, descriptor: abcDescriptor, text: abc), "duplicate setup")
check(
    consumer.popFrame(transaction: 2) { frame in
        check(model.prepare(frame) == .duplicate, "identical revision is idempotent")
        return .commit
    } == .committed,
    "duplicate consumed"
)
let abd = Array("abd".utf8)
check(push(producer, transaction: 3, descriptor: abcDescriptor, text: abd), "conflicting duplicate setup")
check(
    consumer.popFrame(transaction: 3) { frame in
        check(
            model.prepare(frame) == .resynchronizationRequired,
            "conflicting duplicate requires snapshot"
        )
        return .commit
    } == .committed,
    "conflicting duplicate consumed"
)

let recoveryDescriptor = descriptor(correlation: 4, revision: 2, textLength: abc.count, cursorColumn: 3)
check(push(producer, transaction: 4, descriptor: recoveryDescriptor, text: abc), "recovery snapshot setup")
check(
    consumer.popFrame(transaction: 4) { frame in
        check(model.prepare(frame) == .ready, "snapshot recovers staged state")
        check(model.commit(frame), "snapshot recovery commit")
        return .commit
    } == .committed,
    "recovery snapshot consumed"
)

let lambda = Array("λ".utf8)
let lambdaStyle = [ReixTextSurfaceStyleSpan(offset: 1, length: 2, role: .input)!]
let patchDescriptor = descriptor(
    kind: .patch,
    correlation: 5,
    revision: 3,
    baseRevision: 2,
    patchOffset: 1,
    replacedLength: 1,
    textLength: lambda.count,
    styles: 1,
    cursorColumn: 3
)
check(
    push(producer, transaction: 5, descriptor: patchDescriptor, text: lambda, styles: lambdaStyle),
    "UTF-8 patch setup"
)
check(
    consumer.popFrame(transaction: 5) { frame in
        check(model.prepare(frame) == .ready, "UTF-8 patch ready")
        check(model.commit(frame), "UTF-8 patch commit")
        return .commit
    } == .committed,
    "UTF-8 patch consumed"
)
check(model.textLength == 4, "UTF-8 continuation bytes are not cells")
check(model.styleSpan(at: 0) == lambdaStyle[0], "semantic style span retained")

let futureDescriptor = descriptor(
    kind: .patch,
    correlation: 6,
    revision: 5,
    baseRevision: 3,
    patchOffset: 4,
    textLength: 0,
    cursorColumn: 3
)
check(push(producer, transaction: 6, descriptor: futureDescriptor, text: []), "future revision setup")
check(
    consumer.popFrame(transaction: 6) { frame in
        check(model.prepare(frame) == .resynchronizationRequired, "future revision refused")
        return .commit
    } == .committed,
    "future revision consumed"
)

let resized = Array("ready".utf8)
let resizedDescriptor = descriptor(
    correlation: 7,
    revision: 4,
    textLength: resized.count,
    columns: 40,
    rows: 12,
    cursorColumn: 5,
    viewportRows: 3
)
check(push(producer, transaction: 7, descriptor: resizedDescriptor, text: resized), "geometry snapshot setup")
check(
    consumer.popFrame(transaction: 7) { frame in
        check(model.prepare(frame) == .ready, "geometry changes require a snapshot")
        check(model.commit(frame), "geometry snapshot commit")
        return .commit
    } == .committed,
    "geometry snapshot consumed"
)
check(model.interactiveRows == 3, "quarter viewport at 40 by 12")
check(ReixTextSurfaceFrameDescriptor.interactiveRows(for: 24) == 6, "quarter viewport at 80 by 24")
check(ReixTextSurfaceFrameDescriptor.interactiveRows(for: 60) == 15, "quarter viewport cap at 240 by 60")
check(ReixTextSurfaceFrameDescriptor.interactiveRows(for: 3) == 1, "short terminal keeps one row")

check(ReixTextSurfaceRing.initialize(page: page, token: 27), "mode transition proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 27, epoch: 28), "mode transition accept")
producer = ReixTextSurfaceRing(page: page, token: 27, epoch: 28)!
consumer = ReixTextSurfaceRing(page: page, token: 27, epoch: 28)!
var modeModel    = TextSurfaceScreenModel()
var modeTerminal = TerminalScreenModel(columns: 20, rows: 16)
let prompt       = Array("reix> x".utf8)
let promptStyle  = [
    ReixTextSurfaceStyleSpan(offset: 0, length: 6, role: .prompt)!
]
let promptDescriptor = descriptor(
    textLength: prompt.count,
    styles: promptStyle.count,
    columns: 20,
    rows: 16,
    cursorColumn: 7,
    viewportRows: 1
)
check(
    push(
        producer,
        transaction: 1,
        descriptor: promptDescriptor,
        text: prompt,
        styles: promptStyle
    ),
    "editor mode setup"
)
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: modeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(
            occurrences(of: [0x1B, 0x5B, 0x32, 0x4A], in: bytes) == 0,
            "a shell starting does not wipe what the terminal already shows"
        )
        check(feed(bytes, into: &modeTerminal), "editor mode VT is accepted")
        check(modeModel.commit(frame), "editor mode commit")
        return .commit
    } == .committed,
    "editor mode consumed"
)
check(modeTerminal.line(15).hasPrefix("reix> x"), "the prompt sits on the last row")
check(modeTerminal.cursorRow == 15, "the editor opens at the bottom, like a terminal")
check(modeTerminal.cursorColumn == 7, "the editor cursor sits after the typed text")
check(modeModel.editorAnchorRow == 16, "the block is anchored on the flow row")
check(modeModel.editorRows == 1, "one row is claimed")

let multilineSuffix     = Array("\none\ntwo\nthree".utf8)
let multiline           = prompt + multilineSuffix
let multilineDescriptor = descriptor(
    kind: .patch,
    correlation: 2,
    revision: 2,
    baseRevision: 1,
    patchOffset: UInt32(prompt.count),
    textLength: multilineSuffix.count,
    styles: promptStyle.count,
    columns: 20,
    rows: 16,
    cursorRow: 3,
    cursorColumn: 5,
    viewportRows: 4
)
check(
    push(
        producer,
        transaction: 2,
        descriptor: multilineDescriptor,
        text: multilineSuffix,
        styles: promptStyle
    ),
    "multiline editor setup"
)
check(
    consumer.popFrame(transaction: 2) { frame in
        let metrics = TextSurfaceVTRenderer.metrics(screen: modeModel, frame: frame)
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(
            screen: modeModel,
            frame: frame,
            useDiff: metrics.usesDiff
        ) { bytes.append($0) }
        check(feed(bytes, into: &modeTerminal), "multiline editor VT is accepted")
        check(modeModel.commit(frame), "multiline editor commit")
        return .commit
    } == .committed,
    "multiline editor consumed"
)
check(modeModel.editorAnchorRow == 13, "growth scrolls the screen rather than moving the block down")
check(modeModel.editorRows == 4, "four rows are claimed")
check(modeTerminal.line(12).hasPrefix("reix> x"), "the prompt row moved up with the screen")
check(modeTerminal.line(15).hasPrefix("three"), "the last typed row is still the last row")
check(modeTerminal.cursorRow == 15, "the cursor stays on the row being typed")

let promoteDescriptor = descriptor(
    kind: .patch,
    mode: .transcript,
    correlation: 3,
    revision: 3,
    baseRevision: 2,
    textLength: multiline.count,
    styles: promptStyle.count,
    columns: 20,
    rows: 16,
    viewportRows: 1
)
check(
    push(
        producer,
        transaction: 3,
        descriptor: promoteDescriptor,
        text: multiline,
        styles: promptStyle
    ),
    "submitted line setup"
)
check(
    consumer.popFrame(transaction: 3) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: modeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(
            occurrences(of: [0x1B, 0x5B, 0x32, 0x4B], in: bytes) == 4,
            "retiring the block gives back every row it held"
        )
        check(occurrences(of: [0x1B, 0x5B, 0x32, 0x4A], in: bytes) == 0, "no full-screen wipe")
        check(feed(bytes, into: &modeTerminal), "submitted line VT is accepted")
        check(modeModel.commit(frame), "submitted line commit")
        return .commit
    } == .committed,
    "submitted line consumed"
)
check(modeTerminal.line(12).hasPrefix("reix> x"), "the submitted line becomes transcript in place")
check(modeTerminal.line(15).hasPrefix("three"), "every editor row is kept")
check(!modeModel.editorPainted, "no block is on screen after a submit")

let result           = Array("\nresult".utf8)
let resultDescriptor = descriptor(
    kind: .patch,
    mode: .transcript,
    correlation: 4,
    revision: 4,
    baseRevision: 3,
    textLength: result.count,
    columns: 20,
    rows: 16,
    viewportRows: 1
)
check(
    push(producer, transaction: 4, descriptor: resultDescriptor, text: result),
    "transcript mode setup"
)
check(
    consumer.popFrame(transaction: 4) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: modeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &modeTerminal), "transcript mode VT is accepted")
        check(modeModel.commit(frame), "transcript mode commit")
        return .commit
    } == .committed,
    "transcript mode consumed"
)
check(modeTerminal.line(11).hasPrefix("reix> x"), "output scrolls the submitted line up, it does not erase it")
check(modeTerminal.line(14).hasPrefix("three"), "the whole submitted block scrolled together")
check(modeTerminal.line(15).hasPrefix("result"), "output follows on the last row")
check(modeTerminal.cursorRow == 15, "the cursor stays at the bottom")
check(modeTerminal.cursorColumn == 6, "the transcript cursor follows appended output")
check(
    modeModel.flowRow == 16 && modeModel.flowColumn == 6,
    "the model tracks the cursor the terminal actually has"
)

check(ReixTextSurfaceRing.initialize(page: page, token: 45), "code editor proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 45, epoch: 46), "code editor accept")
producer = ReixTextSurfaceRing(page: page, token: 45, epoch: 46)!
consumer = ReixTextSurfaceRing(page: page, token: 45, epoch: 46)!
var codeModel    = TextSurfaceScreenModel()
var codeTerminal = TerminalScreenModel(columns: 20, rows: 16)
let codeText     = Array("alpha\nbeta".utf8)
let codeStyle    = [
    ReixTextSurfaceStyleSpan(offset: 0, length: UInt16(codeText.count), role: .input)!
]
let codeDescriptor = descriptor(
    mode: .codeEditor,
    textLength: codeText.count,
    styles: codeStyle.count,
    columns: 20,
    rows: 16,
    cursorRow: 2,
    cursorColumn: 11,
    viewportRows: 4
)
check(
    push(
        producer,
        transaction: 1,
        descriptor: codeDescriptor,
        text: codeText,
        styles: codeStyle
    ),
    "code editor snapshot setup"
)
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: codeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &codeTerminal), "code editor snapshot VT is accepted")
        check(codeModel.commit(frame), "code editor snapshot commit")
        return .commit
    } == .committed,
    "code editor snapshot consumed"
)
check(codeTerminal.line(12).hasPrefix("reix❯ Editor Mode"), "code editor owns a branded non-editable header")
check(codeTerminal.cells[12 * 20 + 6].attributes.dim, "code editor title is visually subdued")
check(codeTerminal.line(13).hasPrefix("1    | alpha"), "first gutter starts at the left edge")
check(codeTerminal.line(14).hasPrefix("2    | beta"), "second gutter starts at the left edge")
check(codeTerminal.line(15).hasPrefix("Ctrl+Enter run"), "code editor keeps its submit shortcut on the last row")
check(codeTerminal.cells[15 * 20].attributes.background == 236, "shortcut bar has a distinct background")
check(codeTerminal.cursorRow == 14 && codeTerminal.cursorColumn == 11, "code cursor excludes gutter bytes")

let shortenedCode  = Array("b".utf8)
let shortenedStyle = [
    ReixTextSurfaceStyleSpan(offset: 0, length: 7, role: .input)!
]
let shortenedDescriptor = descriptor(
    kind: .patch,
    mode: .codeEditor,
    correlation: 2,
    revision: 2,
    baseRevision: 1,
    patchOffset: 7,
    replacedLength: 3,
    textLength: shortenedCode.count,
    styles: shortenedStyle.count,
    columns: 20,
    rows: 16,
    cursorRow: 2,
    cursorColumn: 8,
    viewportRows: 4
)
check(
    push(
        producer,
        transaction: 2,
        descriptor: shortenedDescriptor,
        text: shortenedCode,
        styles: shortenedStyle
    ),
    "code editor shortening setup"
)
check(
    consumer.popFrame(transaction: 2) { frame in
        let metrics = TextSurfaceVTRenderer.metrics(screen: codeModel, frame: frame)
        var bytes   : [UInt8] = []
        _ = TextSurfaceVTRenderer.render(
            screen: codeModel,
            frame: frame,
            useDiff: metrics.usesDiff
        ) { bytes.append($0) }
        check(metrics.usesDiff, "same-height code shortening stays incremental")
        check(feed(bytes, into: &codeTerminal), "code shortening VT is accepted")
        check(codeModel.commit(frame), "code shortening commit")
        return .commit
    } == .committed,
    "code shortening consumed"
)
check(codeTerminal.line(14).hasPrefix("2    | b"), "shortened code row keeps its gutter")
check(!codeTerminal.line(14).contains("beta"), "deleted code cells are erased immediately")

let oneLineStyle = [
    ReixTextSurfaceStyleSpan(offset: 0, length: 5, role: .input)!
]
let oneLineDescriptor = descriptor(
    kind: .patch,
    mode: .codeEditor,
    correlation: 3,
    revision: 3,
    baseRevision: 2,
    patchOffset: 5,
    replacedLength: 2,
    textLength: 0,
    styles: oneLineStyle.count,
    columns: 20,
    rows: 16,
    cursorRow: 1,
    cursorColumn: 12,
    viewportRows: 3
)
check(
    push(
        producer,
        transaction: 3,
        descriptor: oneLineDescriptor,
        text: [],
        styles: oneLineStyle
    ),
    "code editor line deletion setup"
)
check(
    consumer.popFrame(transaction: 3) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: codeModel, frame: frame, useDiff: true) {
            bytes.append($0)
        }
        check(feed(bytes, into: &codeTerminal), "code line deletion VT is accepted")
        check(codeModel.commit(frame), "code line deletion commit")
        return .commit
    } == .committed,
    "code line deletion consumed"
)
check(codeTerminal.line(12) == String(repeating: " ", count: 20), "retired rows above the compacted editor are cleared")
check(codeTerminal.line(13).hasPrefix("reix❯ Editor Mode"), "compacted editor stays attached to the bottom")
check(codeTerminal.line(14).hasPrefix("1    | alpha"), "remaining code returns below the moved header")
check(codeTerminal.line(15).hasPrefix("Ctrl+Enter run"), "footer remains on the bottom row")

let submittedDescriptor = descriptor(
    kind: .patch,
    mode: .codeTranscript,
    correlation: 4,
    revision: 4,
    baseRevision: 3,
    textLength: codeText.prefix(5).count,
    styles: oneLineStyle.count,
    columns: 20,
    rows: 16,
    viewportRows: 1
)
check(
    push(
        producer,
        transaction: 4,
        descriptor: submittedDescriptor,
        text: Array(codeText.prefix(5)),
        styles: oneLineStyle
    ),
    "submitted code transcript setup"
)
check(
    consumer.popFrame(transaction: 4) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: codeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &codeTerminal), "submitted code transcript VT is accepted")
        check(codeModel.commit(frame), "submitted code transcript commit")
        return .commit
    } == .committed,
    "submitted code transcript consumed"
)
check(codeTerminal.line(13).hasPrefix("reix❯ Editor Mode"), "submitted script retains its editor header")
check(codeTerminal.line(14).hasPrefix("1    | alpha"), "submitted script retains its gutter")
check(codeTerminal.cells[13 * 20].attributes.background == 236, "submitted header has a dark background")
check(codeTerminal.cells[14 * 20 + 7].attributes.background == 236, "submitted source has a dark background")
check(codeTerminal.cursorRow == 15 && codeTerminal.cursorColumn == 0, "submitted block leaves output on a fresh row")

let diagnosticText       = Array("       ^ syntax\n".utf8)
let diagnosticDescriptor = descriptor(
    kind: .patch,
    mode: .transcript,
    source: 11,
    severity: .error,
    outputKind: .diagnostic,
    correlation: 5,
    revision: 5,
    baseRevision: 4,
    textLength: diagnosticText.count,
    columns: 20,
    rows: 16,
    viewportRows: 1
)
check(
    push(
        producer,
        transaction: 5,
        descriptor: diagnosticDescriptor,
        text: diagnosticText
    ),
    "code diagnostic setup"
)
check(
    consumer.popFrame(transaction: 5) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: codeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &codeTerminal), "native code diagnostic VT is accepted")
        check(codeModel.commit(frame), "native code diagnostic commit")
        return .commit
    } == .committed,
    "native code diagnostic consumed"
)
check(codeTerminal.line(14).contains("^ syntax"), "syntax diagnostic follows the submitted block without repeating source")
check(codeTerminal.cells[14 * 20].attributes.background == 236, "syntax diagnostic shares the script background")
check(codeTerminal.cells.filter { $0.character == "a" }.count >= 1, "submitted source remains visible after its diagnostic")

check(ReixTextSurfaceRing.initialize(page: page, token: 47), "scrolled code editor proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 47, epoch: 48), "scrolled code editor accept")
producer = ReixTextSurfaceRing(page: page, token: 47, epoch: 48)!
consumer = ReixTextSurfaceRing(page: page, token: 47, epoch: 48)!
var scrolledCodeModel    = TextSurfaceScreenModel()
var scrolledCodeTerminal = TerminalScreenModel(columns: 20, rows: 16)
let scrolledCode         = Array("one\ntwo\nthree".utf8)
let scrolledDescriptor   = descriptor(
    mode: .codeEditor,
    textLength: scrolledCode.count,
    columns: 20,
    rows: 16,
    cursorRow: 3,
    cursorColumn: 12,
    viewportRow: 2,
    viewportRows: 4
)
check(push(producer, transaction: 1, descriptor: scrolledDescriptor, text: scrolledCode), "scrolled code setup")
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: scrolledCodeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &scrolledCodeTerminal), "scrolled code VT is accepted")
        check(scrolledCodeModel.commit(frame), "scrolled code commit")
        return .commit
    } == .committed,
    "scrolled code consumed"
)
check(scrolledCodeTerminal.line(12).hasPrefix("reix❯ Editor Mode"), "header stays fixed while document rows scroll")
check(scrolledCodeTerminal.line(13).hasPrefix("2    | two"), "scrolled viewport begins below the fixed header")
check(scrolledCodeTerminal.line(14).hasPrefix("3    | three"), "scrolled viewport keeps the following document row")
check(scrolledCodeTerminal.line(15).hasPrefix("Ctrl+Enter run"), "footer stays fixed while document rows scroll")

check(ReixTextSurfaceRing.initialize(page: page, token: 29), "block bottom proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 29, epoch: 30), "block bottom accept")
producer = ReixTextSurfaceRing(page: page, token: 29, epoch: 30)!
consumer = ReixTextSurfaceRing(page: page, token: 29, epoch: 30)!
var bottomModel            = TextSurfaceScreenModel()
var bottomTerminal         = TerminalScreenModel(columns: 20, rows: 16)
let bottomFiller           = Array(("top" + String(repeating: "\n", count: 12)).utf8)
let bottomFillerDescriptor = descriptor(
    mode: .transcript,
    textLength: bottomFiller.count,
    columns: 20,
    rows: 16,
    viewportRows: 1
)
check(
    push(producer, transaction: 1, descriptor: bottomFillerDescriptor, text: bottomFiller),
    "block bottom filler setup"
)
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: bottomModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &bottomTerminal), "block bottom filler VT is accepted")
        check(bottomModel.commit(frame), "block bottom filler commit")
        return .commit
    } == .committed,
    "block bottom filler consumed"
)
check(bottomModel.flowRow == 16, "the flow cursor stops at the last row")
check(bottomTerminal.line(3).hasPrefix("top"), "twelve line feeds scrolled the marker to row four")

// Six rows of text in a four-row viewport: the break after the last visible row
// belongs to a row nobody can see, and emitting it here would scroll the screen.
let clipped           = Array("a\nb\nc\nd\ne\nf".utf8)
let clippedDescriptor = descriptor(
    correlation: 2,
    revision: 2,
    textLength: clipped.count,
    columns: 20,
    rows: 16,
    cursorRow: 0,
    cursorColumn: 1,
    viewportRows: 4
)
check(
    push(producer, transaction: 2, descriptor: clippedDescriptor, text: clipped),
    "clipped block setup"
)
check(
    consumer.popFrame(transaction: 2) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: bottomModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &bottomTerminal), "clipped block VT is accepted")
        check(bottomModel.commit(frame), "clipped block commit")
        return .commit
    } == .committed,
    "clipped block consumed"
)
check(bottomModel.editorAnchorRow == 13, "the block scrolled three rows free and took them")
check(bottomTerminal.line(0).hasPrefix("top"), "the block scrolled exactly as far as it needed")
check(bottomTerminal.line(12).hasPrefix("a"), "the block starts at its anchor")
check(bottomTerminal.line(15).hasPrefix("d"), "the block stops at the viewport, not at the text")
check(bottomTerminal.cursorRow == 12, "the cursor is on the block's first row")
check(bottomTerminal.cursorColumn == 1, "the cursor is after the first grapheme")

check(ReixTextSurfaceRing.initialize(page: page, token: 25), "Unicode model proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 25, epoch: 26), "Unicode model accept")
producer = ReixTextSurfaceRing(page: page, token: 25, epoch: 26)!
consumer = ReixTextSurfaceRing(page: page, token: 25, epoch: 26)!
model = TextSurfaceScreenModel()
let graphemes = Array("e\u{301}界👩‍💻🇮🇹".utf8)
let graphemeStyle = [
    ReixTextSurfaceStyleSpan(offset: 0, length: UInt16(graphemes.count), role: .input)!
]
let graphemeDescriptor = descriptor(
    revision: 1,
    textLength: graphemes.count,
    styles: 1,
    columns: 6,
    rows: 12,
    cursorRow: 1,
    cursorColumn: 2,
    viewportRows: 3
)
check(
    push(
        producer,
        transaction: 1,
        descriptor: graphemeDescriptor,
        text: graphemes,
        styles: graphemeStyle
    ),
    "Unicode model snapshot"
)
check(
    consumer.popFrame(transaction: 1) { frame in
        check(model.prepare(frame) == .ready, "Unicode model frame ready")
        check(model.commit(frame), "Unicode model frame commit")
        return .commit
    } == .committed,
    "Unicode model snapshot consumed"
)
check(model.cursorRow == 1 && model.cursorColumn == 2, "wide grapheme wraps before the edge")
let splitCluster = Array("x".utf8)
let splitDescriptor = descriptor(
    kind: .patch,
    correlation: 2,
    revision: 2,
    baseRevision: 1,
    patchOffset: 1,
    textLength: splitCluster.count,
    columns: 6,
    rows: 12,
    cursorRow: 1,
    cursorColumn: 3,
    viewportRows: 3
)
check(
    push(producer, transaction: 2, descriptor: splitDescriptor, text: splitCluster),
    "split grapheme patch setup"
)
check(
    consumer.popFrame(transaction: 2) { frame in
        check(model.prepare(frame) == .resynchronizationRequired, "split grapheme patch refused")
        return .commit
    } == .committed,
    "split grapheme patch consumed"
)

for geometry: (columns: UInt16, rows: UInt16) in [(40, 12), (80, 24), (240, 60), (10, 3)] {
    check(ReixTextSurfaceRing.initialize(page: page, token: 31), "renderer proposal")
    check(ReixTextSurfaceRing.accept(page: page, token: 31, epoch: 32), "renderer accept")
    producer = ReixTextSurfaceRing(page: page, token: 31, epoch: 32)!
    consumer = ReixTextSurfaceRing(page: page, token: 31, epoch: 32)!
    var rendererModel = TextSurfaceScreenModel()
    var terminal = TerminalScreenModel(columns: Int(geometry.columns), rows: Int(geometry.rows))
    let initial = Array("reix one\nnext".utf8)
    let initialStyles = [
        ReixTextSurfaceStyleSpan(offset: 0, length: UInt16(initial.count), role: .input)!
    ]
    let visibleRows = ReixTextSurfaceFrameDescriptor.interactiveRows(for: geometry.rows)
    let viewportRow: UInt16 = visibleRows > 1 ? 0 : 1
    let initialDescriptor = descriptor(
        revision: 1,
        textLength: initial.count,
        styles: initialStyles.count,
        columns: geometry.columns,
        rows: geometry.rows,
        cursorRow: 1,
        cursorColumn: 4,
        viewportRow: viewportRow,
        viewportRows: visibleRows
    )
    check(
        push(
            producer,
            transaction: 1,
            descriptor: initialDescriptor,
            text: initial,
            styles: initialStyles
        ),
        "renderer snapshot"
    )
    check(
        consumer.popFrame(transaction: 1) { frame in
            var bytes: [UInt8] = []
            let metrics = TextSurfaceVTRenderer.metrics(screen: rendererModel, frame: frame)
            let rendered = TextSurfaceVTRenderer.render(
                screen: rendererModel,
                frame: frame,
                useDiff: metrics.usesDiff
            ) { bytes.append($0) }
            check(!metrics.usesDiff, "snapshot selects full redraw")
            check(rendered == UInt32(bytes.count), "snapshot byte metric is exact")
            check(feed(bytes, into: &terminal), "snapshot VT is accepted")
            check(rendererModel.commit(frame), "renderer snapshot commit")
            return .commit
        } == .committed,
        "renderer snapshot consumed"
    )

    let suffix = Array("!".utf8)
    let patchStyles = [
        ReixTextSurfaceStyleSpan(
            offset: 0,
            length: UInt16(initial.count + suffix.count),
            role: .input
        )!
    ]
    let patch = descriptor(
        kind: .patch,
        correlation: 2,
        revision: 2,
        baseRevision: 1,
        patchOffset: UInt32(initial.count),
        textLength: suffix.count,
        styles: patchStyles.count,
        columns: geometry.columns,
        rows: geometry.rows,
        cursorRow: 1,
        cursorColumn: 5,
        viewportRow: viewportRow,
        viewportRows: visibleRows
    )
    check(
        push(
            producer,
            transaction: 2,
            descriptor: patch,
            text: suffix,
            styles: patchStyles
        ),
        "renderer patch"
    )
    check(
        consumer.popFrame(transaction: 2) { frame in
            var diffBytes: [UInt8] = []
            var fullBytes: [UInt8] = []
            let metrics = TextSurfaceVTRenderer.metrics(screen: rendererModel, frame: frame)
            let diffCount = TextSurfaceVTRenderer.render(
                screen: rendererModel,
                frame: frame,
                useDiff: true
            ) { diffBytes.append($0) }
            let fullCount = TextSurfaceVTRenderer.render(
                screen: rendererModel,
                frame: frame,
                useDiff: false
            ) { fullBytes.append($0) }
            var diffTerminal = terminal
            var fullTerminal = terminal
            check(diffCount == metrics.diffBytes, "diff byte metric is exact")
            check(fullCount == metrics.fullBytes, "full byte metric is exact")
            check(
                occurrences(of: Array("\u{1B}[?25l".utf8), in: fullBytes) == 1
                    && occurrences(of: Array("\u{1B}[?25h".utf8), in: fullBytes) == 1,
                "full repaint hides the cursor until its final position"
            )
            check(
                occurrences(of: Array("\u{1B}[?2026h".utf8), in: fullBytes) == 0
                    && occurrences(of: Array("\u{1B}[?2026l".utf8), in: fullBytes) == 0,
                "full repaint cannot strand the terminal in synchronized-output mode"
            )
            check(feed(diffBytes, into: &diffTerminal), "diff VT is accepted")
            check(feed(fullBytes, into: &fullTerminal), "full VT is accepted")
            check(diffTerminal.cells == fullTerminal.cells, "diff and full cells are equivalent")
            check(diffTerminal.cursorRow == fullTerminal.cursorRow, "diff and full cursor rows agree")
            check(diffTerminal.cursorColumn == fullTerminal.cursorColumn, "diff and full cursor columns agree")
            check(rendererModel.commit(frame), "renderer patch commit")
            return .commit
        } == .committed,
        "renderer patch consumed"
    )

    let combining = [UInt8(0xCC), UInt8(0x81)]
    let combinedStyles = [
        ReixTextSurfaceStyleSpan(
            offset: 0,
            length: UInt16(initial.count + suffix.count + combining.count),
            role: .input
        )!
    ]
    let combiningPatch = descriptor(
        kind: .patch,
        correlation: 3,
        revision: 3,
        baseRevision: 2,
        patchOffset: UInt32(initial.count + suffix.count),
        textLength: combining.count,
        styles: combinedStyles.count,
        columns: geometry.columns,
        rows: geometry.rows,
        cursorRow: 1,
        cursorColumn: 5,
        viewportRow: viewportRow,
        viewportRows: visibleRows
    )
    check(
        push(
            producer,
            transaction: 3,
            descriptor: combiningPatch,
            text: combining,
            styles: combinedStyles
        ),
        "combining renderer patch"
    )
    check(
        consumer.popFrame(transaction: 3) { frame in
            let metrics = TextSurfaceVTRenderer.metrics(screen: rendererModel, frame: frame)
            check(!metrics.usesDiff, "grapheme-merging patch selects full redraw")
            check(rendererModel.commit(frame), "combining renderer patch commit")
            return .commit
        } == .committed,
        "combining renderer patch consumed"
    )

    let metadataPatch = descriptor(
        kind: .patch,
        correlation: 4,
        revision: 4,
        baseRevision: 3,
        patchOffset: 0,
        textLength: 0,
        styles: combinedStyles.count,
        columns: geometry.columns,
        rows: geometry.rows,
        cursorRow: 1,
        cursorColumn: 4,
        viewportRow: viewportRow,
        viewportRows: visibleRows
    )
    check(
        push(
            producer,
            transaction: 4,
            descriptor: metadataPatch,
            text: [],
            styles: combinedStyles
        ),
        "metadata renderer patch"
    )
    check(
        consumer.popFrame(transaction: 4) { frame in
            let previousCells = terminal.cells
            let metrics = TextSurfaceVTRenderer.metrics(screen: rendererModel, frame: frame)
            var bytes: [UInt8] = []
            _ = TextSurfaceVTRenderer.render(
                screen: rendererModel,
                frame: frame,
                useDiff: true
            ) { bytes.append($0) }
            check(metrics.usesDiff, "metadata patch selects bounded diff")
            check(
                occurrences(of: Array("\u{1B}[?25l".utf8), in: bytes) == 0
                    && occurrences(of: Array("\u{1B}[?25h".utf8), in: bytes) == 0,
                "cursor-only movement emits no visibility flicker"
            )
            check(
                occurrences(of: Array("\u{1B}[?2026h".utf8), in: bytes) == 0,
                "cursor-only movement is not wrapped in a repaint transaction"
            )
            check(feed(bytes, into: &terminal), "metadata VT is accepted")
            check(terminal.cells == previousCells, "metadata patch preserves rendered cells")
            check(rendererModel.commit(frame), "metadata renderer patch commit")
            return .commit
        } == .committed,
        "metadata renderer patch consumed"
    )
}

check(ReixTextSurfaceRing.initialize(page: page, token: 41), "external output proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 41, epoch: 42), "external output accept")
producer = ReixTextSurfaceRing(page: page, token: 41, epoch: 42)!
consumer = ReixTextSurfaceRing(page: page, token: 41, epoch: 42)!
var arbitrationModel    = TextSurfaceScreenModel()
var arbitrationTerminal = TerminalScreenModel(columns: 20, rows: 16)
let editing             = Array("reix> echo vault".utf8)
let editingDescriptor   = descriptor(
    textLength: editing.count,
    columns: 20,
    rows: 16,
    cursorColumn: UInt16(editing.count),
    viewportRows: 1
)
check(
    push(producer, transaction: 1, descriptor: editingDescriptor, text: editing),
    "external output editor setup"
)
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(
            screen: arbitrationModel,
            frame: frame,
            useDiff: false
        ) { bytes.append($0) }
        check(feed(bytes, into: &arbitrationTerminal), "external output editor VT is accepted")
        check(arbitrationModel.commit(frame), "external output editor commit")
        return .commit
    } == .committed,
    "external output editor consumed"
)
let retainedRevision = arbitrationModel.revision
let retainedCursor   = (arbitrationModel.cursorRow, arbitrationModel.cursorColumn)
let asynchronous     = Array("worker done\n".utf8)
asynchronous.withUnsafeBufferPointer { payload in
    let record = ReixTextOutputRecord(
        source: 77,
        severity: .notice,
        kind: .application,
        payloadKind: .utf8Text,
        first: payload.baseAddress!,
        firstCount: payload.count
    )!
    check(record.source == 77, "external record retains authoritative source")
    check(record.severity == .notice, "external record retains severity")
    check(record.kind == .application, "external record retains kind")
    guard let plan = arbitrationModel.planExternalOutput(record) else {
        check(false, "external record is measurable")
        return
    }
    var bytes: [UInt8] = []
    _ = TextSurfaceVTRenderer.renderExternal(
        screen: arbitrationModel,
        record: record,
        plan: plan
    ) { bytes.append($0) }
    check(
        occurrences(of: Array("\u{1B}[?25l".utf8), in: bytes) == 1
            && occurrences(of: Array("\u{1B}[?25h".utf8), in: bytes) == 1,
        "external arbitration freezes and restores the cursor once"
    )
    check(feed(bytes, into: &arbitrationTerminal), "external arbitration VT is accepted")
    arbitrationModel.commitExternalOutput(plan)
}
let injectedVT = Array("\u{1B}[2J".utf8)
injectedVT.withUnsafeBufferPointer { payload in
    let record = ReixTextOutputRecord(
        source: 77,
        severity: .notice,
        kind: .application,
        payloadKind: .utf8Text,
        first: payload.baseAddress!,
        firstCount: payload.count
    )!
    check(
        arbitrationModel.planExternalOutput(record) == nil,
        "external payload cannot inject VT"
    )
}
check(
    arbitrationTerminal.line(14).contains("worker")
        && arbitrationTerminal.line(14).contains("done"),
    "external output is visible as inert text above the editor"
)
check(
    arbitrationTerminal.line(15).hasPrefix("reix> echo vault"),
    "external output redraws the unchanged editor"
)
check(
    arbitrationModel.revision == retainedRevision
        && arbitrationModel.cursorRow == retainedCursor.0
        && arbitrationModel.cursorColumn == retainedCursor.1
        && arbitrationModel.textLength == editing.count,
    "external output does not mutate the user scene"
)
check(
    arbitrationTerminal.cursorRow == 15
        && arbitrationTerminal.cursorColumn == editing.count,
    "external output restores the editor cursor"
)

let proposalPage = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTextSurfaceTransport.regionBytes)
defer { proposalPage.deallocate() }
check(ReixTextSurfaceRing.initialize(page: proposalPage, token: 11), "proposal setup")
proposalPage[12] ^= 0x01
check(!ReixTextSurfaceRing.accept(page: proposalPage, token: 11, epoch: 1), "unknown features refused")
proposalPage[12] ^= 0x01
proposalPage[4] = 1
check(!ReixTextSurfaceRing.accept(page: proposalPage, token: 11, epoch: 1), "old version refused")

// A patch repaints from its offset. That is only correct while what was drawn
// before it still looks the way it was drawn, and highlighting is exactly the
// thing that changes its mind: `lis` is a name being typed, `list` is a verb,
// and the bytes that changed colour are the ones already on screen.
check(ReixTextSurfaceRing.initialize(page: page, token: 57), "restyle proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 57, epoch: 58), "restyle accept")
producer = ReixTextSurfaceRing(page: page, token: 57, epoch: 58)!
consumer = ReixTextSurfaceRing(page: page, token: 57, epoch: 58)!
var restyleModel = TextSurfaceScreenModel()
var restyleTerminal = TerminalScreenModel(columns: 20, rows: 16)

let typed = Array("lis".utf8)
check(
    push(
        producer,
        transaction: 1,
        descriptor: descriptor(
            textLength: typed.count,
            styles: 1,
            columns: 20,
            rows: 16,
            cursorColumn: UInt16(typed.count),
            viewportRows: 1
        ),
        text: typed,
        styles: [ReixTextSurfaceStyleSpan(offset: 0, length: 3, role: .incomplete)!]
    ),
    "restyle setup"
)
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: restyleModel, frame: frame, useDiff: false) { bytes.append($0) }
        check(feed(bytes, into: &restyleTerminal), "restyle setup VT is accepted")
        check(restyleModel.commit(frame), "restyle setup commit")
        return .commit
    } == .committed,
    "restyle setup consumed"
)

func restylePatch(
    _ transaction: UInt32,
    _ offset     : UInt32,
    _ length     : UInt16,
    _ role       : ReixTextSurfaceStyleRole,
    _ byte       : String
) -> Bool {
    push(
        producer,
        transaction: transaction,
        descriptor: descriptor(
            kind: .patch,
            correlation: transaction,
            revision: transaction,
            baseRevision: transaction - 1,
            patchOffset: offset,
            textLength: 1,
            styles: 1,
            columns: 20,
            rows: 16,
            cursorColumn: UInt16(offset) + 1,
            viewportRows: 1
        ),
        text: Array(byte.utf8),
        styles: [ReixTextSurfaceStyleSpan(offset: 0, length: length, role: role)!]
    )
}

// `lis` was grey while it was a name being typed; `list` is a verb. The bytes
// that changed colour are the three already on screen, so this is no diff.
check(restylePatch(2, 3, 4, .command, "t"), "restyle patch pushed")
check(
    consumer.popFrame(transaction: 2) { frame in
        let metrics = TextSurfaceVTRenderer.metrics(screen: restyleModel, frame: frame)
        check(!metrics.usesDiff, "a patch that repaints what came before it is not a diff")
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: restyleModel, frame: frame, useDiff: metrics.usesDiff) {
            bytes.append($0)
        }
        check(feed(bytes, into: &restyleTerminal), "restyled VT is accepted")
        check(everyStyleResets(bytes), "every colour change resets before it adds")
        check(restyleModel.commit(frame), "restyled commit")
        return .commit
    } == .committed,
    "restyle patch consumed"
)
check(
    (0..<16).contains { restyleTerminal.line($0).contains("list") },
    "the whole word is on screen"
)

// One more letter, with the verb still a verb behind it: nothing already
// drawn changed its mind, so the patch stays a patch.
check(restylePatch(3, 4, 5, .command, "s"), "unchanged-paint patch pushed")
check(
    consumer.popFrame(transaction: 3) { frame in
        let metrics = TextSurfaceVTRenderer.metrics(screen: restyleModel, frame: frame)
        check(metrics.usesDiff, "a patch that changes nothing behind it stays a diff")
        return .commit
    } == .committed,
    "unchanged-paint patch consumed"
)

if failures == 0 {
    print("TextSurfaceRingHarness passed \(checks) checks")
} else {
    print("TextSurfaceRingHarness failed \(failures) of \(checks) checks")
    exit(code: 1)
}
