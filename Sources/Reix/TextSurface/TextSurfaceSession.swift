//
//  TextSurfaceSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// The shell owns one TextSurface region and rings the presentation doorbell.
///
/// Two streams share the region and nothing else. Transcript frames carry a chunk
/// of finished output and are forgotten the moment they are acknowledged; editor
/// frames patch a bounded buffer that only ever holds the prompt and the line
/// being typed. The transcript is not mirrored here, so printing cannot run the
/// editor out of room and the editor cannot make output redraw.
public struct TextSurfaceSession: ~Copyable {
    private let endpoint             : UInt32
    private let handle               : UInt32
    private let address              : UInt64
    private let token                : UInt32
    private let epoch                : UInt64
    private let source               : UInt32
    private var usable               = true
    private var transaction          : UInt32 = 0
    private var revision             : UInt32 = 0
    private var requiresSnapshot     = true
    private var editor               = InlineArray<8200, UInt8>(repeating: 0)
    private var editorLength         = 0
    private var editorActive         = false
    private var editorMode           = ReixTextSurfaceFrameMode.editor
    private var editorDesynchronized = false
    private var editorStyles         = InlineArray<32, ReixTextSurfaceStyleSpan>(
        repeating: ReixTextSurfaceStyleSpan(offset: 0, length: 1, role: .plain)!
    )
    private var editorStyleCount = 0
    private var columns          : UInt16 = 80
    private var rows             : UInt16 = 24

    public init?(endpoint: UInt32) {
        let shared = shmCreate(pageCount: UInt64(ReixTextSurfaceTransport.pages))
        guard shared.isValid,
              shared.handle != 0,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let token = shared.handle
        func giveUp() {
            _ = munmap(addr: shared.address, size: UInt64(ReixTextSurfaceTransport.regionBytes))
            _ = capDrop(shared.handle)
        }
        guard ReixTextSurfaceRing.initialize(page: page, token: token) else {
            giveUp()
            return nil
        }
        _ = send(
            handle: endpoint,
            message: ReixTextSurfaceOperation.register.message(
                word0: UInt32(ReixTextSurfaceTransport.pages),
                word1: token
            ),
            grant: shared.handle,
            grantRights: [.send, .read, .write]
        )
        guard case .success(let answer) = call(
            handle: endpoint,
            message: ReixTextSurfaceOperation.status.message(word0: token)
        ),
              answer.message.tag.length == 4,
              ReixTextSurfaceStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == token
        else {
            giveUp()
            return nil
        }
        let epoch = UInt64(answer.message.words[2]) | UInt64(answer.message.words[3]) << 32
        guard epoch != 0, ReixTextSurfaceRing(page: page, token: token, epoch: epoch) != nil else {
            giveUp()
            return nil
        }
        self.endpoint = endpoint
        self.handle = shared.handle
        self.address = shared.address
        self.token = token
        self.epoch = epoch
        self.source = UInt32(truncatingIfNeeded: getPID())
    }

    deinit {
        _ = munmap(addr: address, size: UInt64(ReixTextSurfaceTransport.regionBytes))
        _ = capDrop(handle)
    }

    /// True when the region is still usable. A refused frame is not fatal on its
    /// own; the caller may keep going and the next frame becomes a snapshot.
    public var isUsable: Bool { usable }

    public var hasEditor: Bool { editorActive }

    /// True when the mirror moved but the frame that carried it did not land, so
    /// the next patch would measure from a state nobody else has. The producer
    /// has to send the whole line before patching again.
    public var needsEditorSnapshot: Bool { editorDesynchronized }

    /// Appends finished output at the flow cursor.
    public mutating func append(
        _ bytes   : UnsafePointer<UInt8>,
        count     : Int,
        sequence  : UInt32,
        severity  : ReixTextOutputSeverity = .info,
        kind      : ReixTextOutputKind = .application,
        styles    : UnsafePointer<ReixTextSurfaceStyleSpan>? = nil,
        styleCount: Int = 0
    ) -> Bool {
        guard usable,
              styleCount >= 0,
              styleCount <= Int(ReixTextSurfaceFrameDescriptor.maximumStyleSpans),
              (styleCount == 0) == (styles == nil),
              !editorActive,
              sequence != 0,
              count > 0,
              count <= ReixTextSurfaceFrameDescriptor.maximumTextBytes,
              ReixTextSurfaceProtocol.validText(bytes, count: count)
        else { return false }
        guard let descriptor = transcriptDescriptor(
            severity: severity,
            outputKind: kind,
            correlation: sequence,
            textLength: UInt32(count),
            styleSpanCount: UInt16(styleCount)
        ) else { return false }
        let nextTransaction = advanceTransaction()
        guard let frame = ReixTextSurfaceFrameSource(descriptor: descriptor, text: bytes, styles: styles) else {
            requiresSnapshot = true
            return false
        }
        return settle(sendFrame(frame, transaction: nextTransaction), revision: descriptor.revision)
    }

    /// Records the new geometry. An editor frame carries its own, so this only has
    /// to tell the adapter when no block is up to say it for us.
    public mutating func resize(width: UInt16, height: UInt16, correlation: UInt32) -> Bool {
        guard width > 0,
              width <= ReixTextSurfaceFrameDescriptor.maximumColumns,
              height > 0,
              height <= ReixTextSurfaceFrameDescriptor.maximumRows,
              correlation != 0
        else { return false }
        guard width != columns || height != rows else { return true }
        columns = width
        rows = height
        guard usable, !editorActive else { return true }
        requiresSnapshot = true
        guard let descriptor = transcriptDescriptor(
            correlation: correlation,
            textLength: 0,
            styleSpanCount: 0
        ) else { return false }
        let nextTransaction = advanceTransaction()
        guard let frame = ReixTextSurfaceFrameSource(descriptor: descriptor, text: nil) else {
            requiresSnapshot = true
            return false
        }
        return settle(sendFrame(frame, transaction: nextTransaction), revision: descriptor.revision)
    }

    /// Starts the screen again: nothing on it, and the flow at the last row, so
    /// the block that comes next opens where the input always lives.
    ///
    /// The editor block goes with it. What was typed before is scrollback the
    /// terminal owns, and this is the shell saying it would like none of it.
    public mutating func clear(sequence: UInt32) -> Bool {
        guard usable, sequence != 0 else { return false }
        _ = finishEditor(sequence: sequence)
        guard let nextRevision = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision),
              let descriptor = ReixTextSurfaceFrameDescriptor(
                  kind: .snapshot,
                  mode: .reset,
                  source: source,
                  correlation: sequence,
                  revision: nextRevision,
                  baseRevision: 0,
                  textLength: 0,
                  columns: columns,
                  rows: rows,
                  cursorRow: 0,
                  cursorColumn: 0,
                  viewportRows: 1
              ),
              let frame = ReixTextSurfaceFrameSource(descriptor: descriptor, text: nil)
        else {
            requiresSnapshot = true
            return false
        }
        let presented = sendFrame(frame, transaction: advanceTransaction())
        requiresSnapshot = true
        return settle(presented, revision: nextRevision)
    }

    public mutating func finishEditor(sequence: UInt32) -> Bool {
        guard editorActive else { return true }
        let promotedMode: ReixTextSurfaceFrameMode = editorMode == .codeEditor
            ? .codeTranscript
            : .transcript
        editorActive = false
        editorDesynchronized = false
        let promoted   = editorLength
        let styleCount = editorStyleCount
        editorLength = 0
        editorStyleCount = 0
        guard usable, promoted > 0, sequence != 0 else { return true }
        guard let descriptor = transcriptDescriptor(
            mode: promotedMode,
            correlation: sequence,
            textLength: UInt32(promoted),
            styleSpanCount: UInt16(styleCount)
        ) else {
            requiresSnapshot = true
            return false
        }
        let nextTransaction = advanceTransaction()
        let presented       = editor.span.withUnsafeBufferPointer { bytes in
            withUnsafeTemporaryAllocation(
                of: ReixTextSurfaceStyleSpan.self,
                capacity: max(1, styleCount)
            ) { spans in
                for index in 0..<styleCount { spans[index] = editorStyles[index] }
                guard let frame = ReixTextSurfaceFrameSource(
                    descriptor: descriptor,
                    text: bytes.baseAddress!,
                    styles: styleCount == 0 ? nil : UnsafePointer(spans.baseAddress!)
                ) else { return false }
                return sendFrame(frame, transaction: nextTransaction)
            }
        }
        return settle(presented, revision: descriptor.revision)
    }

    /// Native producers keep their frame storage alive until this call returns.
    public mutating func present(_ frame: ReixTextSurfaceFrameSource) -> Bool {
        guard usable else { return false }
        let nextTransaction = advanceTransaction()
        return settle(
            sendFrame(frame, transaction: nextTransaction),
            revision: frame.descriptor.revision
        )
    }

    /// Builds the revision fence while the caller keeps segmented frame storage alive.
    public mutating func presentNative(
        kind             : ReixTextSurfaceFrameKind,
        mode             : ReixTextSurfaceFrameMode = .editor,
        correlation      : UInt32,
        patchOffset      : UInt32,
        replacedLength   : UInt32,
        textLength       : UInt32,
        text0            : UnsafePointer<UInt8>?,
        text0Length      : Int,
        text1            : UnsafePointer<UInt8>?,
        text1Length      : Int,
        text2            : UnsafePointer<UInt8>?,
        text2Length      : Int,
        styles           : UnsafePointer<ReixTextSurfaceStyleSpan>?,
        styleCount       : Int,
        columns          : UInt16,
        rows             : UInt16,
        cursorOffset     : UInt32,
        viewportRow      : UInt16,
        viewportRows     : UInt16,
        overlay          : UnsafePointer<UInt8>? = nil,
        overlayLength    : Int = 0,
        overlayStyles    : UnsafePointer<ReixTextSurfaceStyleSpan>? = nil,
        overlayStyleCount: Int = 0,
        overlayRow       : UInt16 = 0,
        overlayColumn    : UInt16 = 0,
        overlayRows      : UInt16 = 0,
        overlayColumns   : UInt16 = 0
    ) -> Bool {
        guard usable,
              overlayLength >= 0,
              overlayLength <= ReixTextSurfaceFrameDescriptor.maximumOverlayBytes,
              overlayStyleCount >= 0,
              overlayStyleCount <= Int(ReixTextSurfaceFrameDescriptor.maximumOverlayStyleSpans),
              (overlayLength == 0) == (overlay == nil),
              (overlayStyleCount == 0) == (overlayStyles == nil),
              mode != .transcript,
              correlation != 0,
              columns > 0,
              columns <= ReixTextSurfaceFrameDescriptor.maximumColumns,
              rows > 0,
              rows <= ReixTextSurfaceFrameDescriptor.maximumRows,
              viewportRows > 0,
              viewportRows <= ReixTextSurfaceFrameDescriptor.interactiveRows(for: rows),
              styleCount >= 0,
              styleCount <= Int(ReixTextSurfaceFrameDescriptor.maximumStyleSpans),
              text0Length >= 0,
              text1Length >= 0,
              text2Length >= 0,
              text0Length <= Int(textLength),
              text1Length <= Int(textLength) - text0Length,
              text2Length == Int(textLength) - text0Length - text1Length,
              (text0Length == 0) == (text0 == nil),
              (text1Length == 0) == (text1 == nil),
              (text2Length == 0) == (text2 == nil),
              (styleCount == 0) == (styles == nil),
              textLength <= UInt32(ReixTextSurfaceFrameDescriptor.maximumTextBytes),
              let nextRevision = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision)
        else { return false }

        let localOffset: Int
        let removed: Int
        if kind == .snapshot {
            guard patchOffset == 0, replacedLength == 0 else { return false }
            localOffset = 0
            removed = editorLength
        } else {
            guard editorActive,
                  !editorDesynchronized,
                  Int(patchOffset) <= editorLength,
                  Int(replacedLength) <= editorLength - Int(patchOffset),
                  ReixTextLayout.isGraphemeBoundary(
                      Int(patchOffset),
                      count: editorLength,
                      byte: { editor[$0] }
                  ),
                  ReixTextLayout.isGraphemeBoundary(
                      Int(patchOffset + replacedLength),
                      count: editorLength,
                      byte: { editor[$0] }
                  )
            else { return false }
            localOffset = Int(patchOffset)
            removed = Int(replacedLength)
        }
        let inserted   = Int(textLength)
        let nextLength = editorLength - removed + inserted
        guard nextLength >= 0,
              nextLength <= editor.count,
              Int(cursorOffset) <= nextLength,
              editorResultValid(
                  count: nextLength,
                  offset: localOffset,
                  removed: removed,
                  text0: text0,
                  text0Length: text0Length,
                  text1: text1,
                  text1Length: text1Length,
                  text2: text2,
                  text2Length: text2Length
              ),
              editorResultBoundary(
                  Int(cursorOffset),
                  count: nextLength,
                  offset: localOffset,
                  removed: removed,
                  text0: text0,
                  text0Length: text0Length,
                  text1: text1,
                  text1Length: text1Length,
                  text2: text2,
                  text2Length: text2Length
              ),
              spansValid(
                  styles,
                  count: styleCount,
                  textLength: nextLength,
                  offset: localOffset,
                  removed: removed,
                  text0: text0,
                  text0Length: text0Length,
                  text1: text1,
                  text1Length: text1Length,
                  text2: text2,
                  text2Length: text2Length
              )
        else { return false }

        guard replaceEditor(
            at: localOffset,
            removed: removed,
            text0: text0,
            text0Length: text0Length,
            text1: text1,
            text1Length: text1Length,
            text2: text2,
            text2Length: text2Length
        ) else { return false }
        let resized     = columns != self.columns || rows != self.rows
        let modeChanged = editorActive && mode != editorMode
        self.columns = columns
        self.rows = rows
        editorLength = nextLength
        editorActive = true
        editorMode = mode
        editorStyleCount = styleCount
        for index in 0..<styleCount { editorStyles[index] = styles![index] }

        // An overlay is drawn over rows the editor also owns, so a frame that
        // carries or drops one repaints rather than patches.
        let snapshot = kind == .snapshot || requiresSnapshot || revision == 0 || resized || modeChanged
            || overlayLength > 0
        let cursor   : ReixTextLayout.Position?
        if mode == .codeEditor {
            cursor = ReixCodeEditorLayout.position(
                at: Int(cursorOffset),
                count: editorLength,
                columns: columns,
                byte: { editor[$0] }
            )
        } else {
            cursor = ReixTextLayout.position(
                at: Int(cursorOffset),
                count: editorLength,
                columns: columns,
                byte: { editor[$0] }
            )
        }
        guard let cursor else {
            requiresSnapshot = true
            return false
        }
        let minimumViewport = cursor.row >= viewportRows ? cursor.row - viewportRows + 1 : 0
        let actualViewport  = min(cursor.row, max(viewportRow, minimumViewport))
        guard let descriptor = ReixTextSurfaceFrameDescriptor(
            kind: snapshot ? .snapshot : .patch,
            mode: mode,
            source: source,
            correlation: correlation,
            revision: nextRevision,
            baseRevision: snapshot ? 0 : revision,
            patchOffset: snapshot ? 0 : UInt32(localOffset),
            replacedLength: snapshot ? 0 : UInt32(removed),
            textLength: UInt32(snapshot ? editorLength : inserted),
            overlayLength: UInt16(overlayLength),
            styleSpanCount: UInt16(styleCount),
            overlayStyleSpanCount: UInt16(overlayStyleCount),
            columns: columns,
            rows: rows,
            cursorRow: cursor.row,
            cursorColumn: cursor.column,
            viewportRow: actualViewport,
            viewportRows: viewportRows,
            overlayRow: overlayRow,
            overlayColumn: overlayColumn,
            overlayRows: overlayRows,
            overlayColumns: overlayColumns
        ) else {
            requiresSnapshot = true
            return false
        }
        let nextTransaction = advanceTransaction()
        let presented       = editor.span.withUnsafeBufferPointer { bytes in
            withUnsafeTemporaryAllocation(
                of: ReixTextSurfaceStyleSpan.self,
                capacity: max(1, styleCount)
            ) { spans in
                for index in 0..<styleCount { spans[index] = editorStyles[index] }
                let sourceOffset = snapshot ? 0 : localOffset
                let sourceLength = snapshot ? editorLength : inserted
                guard let source = ReixTextSurfaceFrameSource(
                    descriptor: descriptor,
                    text: sourceLength == 0 ? nil : bytes.baseAddress!.advanced(by: sourceOffset),
                    styles: styleCount == 0 ? nil : UnsafePointer(spans.baseAddress!),
                    overlay: overlay,
                    overlayStyles: overlayStyles
                ) else { return false }
                return sendFrame(source, transaction: nextTransaction)
            }
        }
        // The mirror moved before the frame did. If the frame did not land, the
        // next patch would be measured against a state only this side has.
        editorDesynchronized = !presented
        return settle(presented, revision: nextRevision)
    }

    private mutating func advanceTransaction() -> UInt32 {
        let next = transaction == UInt32.max ? 1 : transaction + 1
        transaction = next
        return next
    }

    private mutating func settle(
        _ presented  : Bool,
        revision next: UInt32
    ) -> Bool {
        if presented {
            revision = next
            requiresSnapshot = false
        } else {
            requiresSnapshot = true
        }
        return presented
    }

    private mutating func transcriptDescriptor(
        mode          : ReixTextSurfaceFrameMode = .transcript,
        severity      : ReixTextOutputSeverity = .info,
        outputKind    : ReixTextOutputKind = .application,
        correlation   : UInt32,
        textLength    : UInt32,
        styleSpanCount: UInt16
    ) -> ReixTextSurfaceFrameDescriptor? {
        guard let nextRevision = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision) else {
            usable = false
            return nil
        }
        let snapshot = requiresSnapshot || revision == 0
        return ReixTextSurfaceFrameDescriptor(
            kind: snapshot ? .snapshot : .patch,
            mode: mode,
            source: source,
            severity: severity,
            outputKind: outputKind,
            correlation: correlation,
            revision: nextRevision,
            baseRevision: snapshot ? 0 : revision,
            textLength: textLength,
            styleSpanCount: styleSpanCount,
            columns: columns,
            rows: rows,
            cursorRow: 0,
            cursorColumn: 0,
            viewportRow: 0,
            viewportRows: 1
        )
    }

    private func sendFrame(
        _ frame    : ReixTextSurfaceFrameSource,
        transaction: UInt32
    ) -> Bool {
        guard usable,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixTextSurfaceRing(page: page, token: token, epoch: epoch)
        else { return false }
        guard ring.push(transaction: transaction, frame: frame) else { return false }

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = transaction
        words[1] = token
        words[2] = UInt32(truncatingIfNeeded: epoch)
        words[3] = UInt32(truncatingIfNeeded: epoch >> 32)
        guard case .success(let answer) = call(
            handle: endpoint,
            message: Message(tag: MessageTag(ReixTextSurfaceOperation.present, length: 4), words: words)
        ),
              answer.message.tag.label == ReixTextSurfaceOperation.present.rawValue,
              answer.message.tag.length == 4,
              answer.message.words[1] == transaction,
              answer.message.words[2] == token,
              answer.message.words[3] == UInt32(truncatingIfNeeded: epoch),
              let status          = ReixTextSurfaceStatus(rawValue: answer.message.words[0]),
              let acknowledgement = ring.acknowledgement(transaction: transaction),
              acknowledgement.revision == frame.descriptor.revision,
              acknowledgement.baseRevision == frame.descriptor.baseRevision
        else { return false }
        switch (status, acknowledgement.status) {
            case (.ok, .committed): return true
            case (.backpressure, _), (.snapshotRequired, .snapshotRequired),
                 (.hardwareFailure, .hardwareFailure): return false
            default: return false
        }
    }

    private func segmentedByte(
        at index: Int,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> UInt8? {
        guard index >= 0, index < text0Length + text1Length + text2Length else { return nil }
        if index < text0Length { return text0![index] }
        let after0 = index - text0Length
        if after0 < text1Length { return text1![after0] }
        return text2![after0 - text1Length]
    }

    private func editorResultByte(
        at index   : Int,
        count      : Int,
        offset     : Int,
        removed    : Int,
        text0      : UnsafePointer<UInt8>?,
        text0Length: Int,
        text1      : UnsafePointer<UInt8>?,
        text1Length: Int,
        text2      : UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> UInt8? {
        guard index >= 0, index < count else { return nil }
        let inserted = text0Length + text1Length + text2Length
        if index < offset { return editor[index] }
        if index < offset + inserted {
            return segmentedByte(
                at: index - offset,
                text0: text0,
                text0Length: text0Length,
                text1: text1,
                text1Length: text1Length,
                text2: text2,
                text2Length: text2Length
            )
        }
        return editor[index - inserted + removed]
    }

    private func editorResultValid(
        count      : Int,
        offset     : Int,
        removed    : Int,
        text0      : UnsafePointer<UInt8>?,
        text0Length: Int,
        text1      : UnsafePointer<UInt8>?,
        text1Length: Int,
        text2      : UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        ReixTextLayout.validUTF8(count: count) {
            editorResultByte(
                at: $0,
                count: count,
                offset: offset,
                removed: removed,
                text0: text0,
                text0Length: text0Length,
                text1: text1,
                text1Length: text1Length,
                text2: text2,
                text2Length: text2Length
            )
        }
    }

    private func editorResultBoundary(
        _ boundary : Int,
        count      : Int,
        offset     : Int,
        removed    : Int,
        text0      : UnsafePointer<UInt8>?,
        text0Length: Int,
        text1      : UnsafePointer<UInt8>?,
        text1Length: Int,
        text2      : UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        ReixTextLayout.isGraphemeBoundary(boundary, count: count) {
            editorResultByte(
                at: $0,
                count: count,
                offset: offset,
                removed: removed,
                text0: text0,
                text0Length: text0Length,
                text1: text1,
                text1Length: text1Length,
                text2: text2,
                text2Length: text2Length
            )
        }
    }

    private func spansValid(
        _ styles: UnsafePointer<ReixTextSurfaceStyleSpan>?,
        count: Int,
        textLength: Int,
        offset: Int,
        removed: Int,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        var previousEnd = 0
        for index in 0..<count {
            let span = styles![index]
            let start = Int(span.offset)
            let end = start + Int(span.length)
            guard start >= previousEnd,
                  end <= textLength,
                  editorResultBoundary(
                      start,
                      count: textLength,
                      offset: offset,
                      removed: removed,
                      text0: text0,
                      text0Length: text0Length,
                      text1: text1,
                      text1Length: text1Length,
                      text2: text2,
                      text2Length: text2Length
                  ),
                  editorResultBoundary(
                      end,
                      count: textLength,
                      offset: offset,
                      removed: removed,
                      text0: text0,
                      text0Length: text0Length,
                      text1: text1,
                      text1Length: text1Length,
                      text2: text2,
                      text2Length: text2Length
                  )
            else { return false }
            previousEnd = end
        }
        return true
    }

    private mutating func replaceEditor(
        at offset  : Int,
        removed    : Int,
        text0      : UnsafePointer<UInt8>?,
        text0Length: Int,
        text1      : UnsafePointer<UInt8>?,
        text1Length: Int,
        text2      : UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        let inserted = text0Length + text1Length + text2Length
        guard offset >= 0,
              removed >= 0,
              offset <= editorLength,
              removed <= editorLength - offset,
              editorLength - removed <= editor.count - inserted
        else { return false }
        let tailStart = offset + removed
        let tailCount = editorLength - tailStart
        if inserted > removed {
            var index = tailCount
            while index > 0 {
                index -= 1
                editor[offset + inserted + index] = editor[tailStart + index]
            }
        } else if inserted < removed {
            for index in 0..<tailCount {
                editor[offset + inserted + index] = editor[tailStart + index]
            }
        }
        var destination = offset
        for index in 0..<text0Length { editor[destination + index] = text0![index] }
        destination += text0Length
        for index in 0..<text1Length { editor[destination + index] = text1![index] }
        destination += text1Length
        for index in 0..<text2Length { editor[destination + index] = text2![index] }
        editorLength = editorLength - removed + inserted
        return true
    }
}
