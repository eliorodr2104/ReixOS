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

private func descriptor(
    kind: ReixTextSurfaceFrameKind = .snapshot,
    mode: ReixTextSurfaceFrameMode = .editor,
    correlation: UInt32 = 1,
    revision: UInt32 = 1,
    baseRevision: UInt32 = 0,
    patchOffset: UInt32 = 0,
    replacedLength: UInt32 = 0,
    textLength: Int,
    overlayLength: Int = 0,
    styles: Int = 0,
    overlayStyles: Int = 0,
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    cursorRow: UInt16 = 0,
    cursorColumn: UInt16 = 0,
    viewportRow: UInt16 = 0,
    viewportRows: UInt16 = 6,
    overlayRows: UInt16 = 0,
    overlayColumns: UInt16 = 0
) -> ReixTextSurfaceFrameDescriptor {
    ReixTextSurfaceFrameDescriptor(
        kind: kind,
        mode: mode,
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
var modeModel = TextSurfaceScreenModel()
var modeTerminal = TerminalScreenModel(columns: 20, rows: 8)
let prompt = Array("reix> x".utf8)
let promptDescriptor = descriptor(
    textLength: prompt.count,
    columns: 20,
    rows: 8,
    cursorColumn: 7,
    viewportRows: 1
)
check(push(producer, transaction: 1, descriptor: promptDescriptor, text: prompt), "editor mode setup")
check(
    consumer.popFrame(transaction: 1) { frame in
        var bytes: [UInt8] = []
        _ = TextSurfaceVTRenderer.render(screen: modeModel, frame: frame, useDiff: false) {
            bytes.append($0)
        }
        check(feed(bytes, into: &modeTerminal), "editor mode VT is accepted")
        check(modeModel.commit(frame), "editor mode commit")
        return .commit
    } == .committed,
    "editor mode consumed"
)
check(modeTerminal.cursorRow == 7, "one-row editor is anchored at the bottom")
let result = Array("\nresult".utf8)
let transcriptDescriptor = descriptor(
    kind: .patch,
    mode: .transcript,
    correlation: 2,
    revision: 2,
    baseRevision: 1,
    patchOffset: UInt32(prompt.count),
    textLength: result.count,
    columns: 20,
    rows: 8,
    cursorRow: 1,
    cursorColumn: 6,
    viewportRow: 1,
    viewportRows: 1
)
check(
    push(producer, transaction: 2, descriptor: transcriptDescriptor, text: result),
    "transcript mode setup"
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
        check(metrics.usesDiff, "editor to transcript transition appends")
        check(feed(bytes, into: &modeTerminal), "transcript mode VT is accepted")
        check(modeModel.commit(frame), "transcript mode commit")
        return .commit
    } == .committed,
    "transcript mode consumed"
)
check(modeTerminal.cursorRow == 7, "transcript output scrolls from the editor cursor")
check(modeTerminal.cursorColumn == 6, "transcript cursor follows appended output")

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
            check(feed(bytes, into: &terminal), "metadata VT is accepted")
            check(terminal.cells == previousCells, "metadata patch preserves rendered cells")
            check(rendererModel.commit(frame), "metadata renderer patch commit")
            return .commit
        } == .committed,
        "metadata renderer patch consumed"
    )
}

let proposalPage = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTextSurfaceTransport.regionBytes)
defer { proposalPage.deallocate() }
check(ReixTextSurfaceRing.initialize(page: proposalPage, token: 11), "proposal setup")
proposalPage[12] ^= 0x01
check(!ReixTextSurfaceRing.accept(page: proposalPage, token: 11, epoch: 1), "unknown features refused")
proposalPage[12] ^= 0x01
proposalPage[4] = 1
check(!ReixTextSurfaceRing.accept(page: proposalPage, token: 11, epoch: 1), "old version refused")

if failures == 0 {
    print("TextSurfaceRingHarness passed \(checks) checks")
} else {
    print("TextSurfaceRingHarness failed \(failures) of \(checks) checks")
    exit(code: 1)
}
