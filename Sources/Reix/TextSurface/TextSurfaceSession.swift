//
//  TextSurfaceSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// The shell owns one TextSurface region and rings the presentation doorbell.
public struct TextSurfaceSession: ~Copyable {
    private let endpoint: UInt32
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64
    private var usable = true
    private var transaction: UInt32 = 0
    private var revision: UInt32 = 0
    private var requiresSnapshot = true
    private var compatibility = InlineArray<8200, UInt8>(repeating: 0)
    private var compatibilityCount = 0
    private var compatibilityCursor = 0
    private var nativeActive = false
    private var nativeAnchor = 0
    private var nativeLength = 0
    private var columns: UInt16 = 80
    private var rows: UInt16 = 24

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
    }

    deinit {
        _ = munmap(addr: address, size: UInt64(ReixTextSurfaceTransport.regionBytes))
        _ = capDrop(handle)
    }

    /// Legacy editor commands are producer input only. The ring carries v2 frames.
    public mutating func present(_ command: ReixTextSurfaceCommand) -> Bool {
        guard usable,
              !nativeActive,
              prepareCompatibility(for: command),
              let change = compatibilityChange(for: command),
              apply(command)
        else { return false }
        return presentCompatibility(correlation: command.sequence, change: change)
    }

    public mutating func resize(width: UInt16, height: UInt16, correlation: UInt32) -> Bool {
        guard !nativeActive,
              width > 0,
              width <= ReixTextSurfaceFrameDescriptor.maximumColumns,
              height > 0,
              height <= ReixTextSurfaceFrameDescriptor.maximumRows,
              correlation != 0
        else { return false }
        columns = width
        rows = height
        requiresSnapshot = true
        return presentCompatibility(correlation: correlation, change: .metadata)
    }

    /// Ends native editor ownership before structured shell output is appended.
    public mutating func finishNative() {
        guard nativeActive else { return }
        compatibilityCursor = nativeAnchor + nativeLength
        nativeActive = false
        nativeLength = 0
    }

    /// Native v2 producers keep their frame storage alive until this call returns.
    public mutating func present(_ frame: ReixTextSurfaceFrameSource) -> Bool {
        guard usable else { return false }
        let nextTransaction = transaction == UInt32.max ? 1 : transaction + 1
        transaction = nextTransaction
        guard sendFrame(frame, transaction: nextTransaction) else {
            requiresSnapshot = true
            return false
        }
        revision = frame.descriptor.revision
        requiresSnapshot = false
        return true
    }

    /// Builds the revision fence while the caller keeps segmented frame storage alive.
    public mutating func presentNative(
        kind: ReixTextSurfaceFrameKind,
        correlation: UInt32,
        patchOffset: UInt32,
        replacedLength: UInt32,
        textLength: UInt32,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int,
        styles: UnsafePointer<ReixTextSurfaceStyleSpan>?,
        styleCount: Int,
        columns: UInt16,
        rows: UInt16,
        cursorOffset: UInt32,
        viewportRow: UInt16,
        viewportRows: UInt16
    ) -> Bool {
        guard usable,
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

        if nativeActive {
            guard nativeAnchor <= compatibilityCount,
                  nativeLength <= compatibilityCount - nativeAnchor
            else { return false }
        }
        let frameAnchor = nativeActive ? nativeAnchor : compatibilityCount
        let localOffset: Int
        let removed: Int
        if kind == .snapshot {
            guard patchOffset == 0, replacedLength == 0 else { return false }
            localOffset = 0
            removed = nativeActive ? nativeLength : 0
        } else {
            guard nativeActive,
                  Int(patchOffset) <= nativeLength,
                  Int(replacedLength) <= nativeLength - Int(patchOffset),
                  ReixTextLayout.isGraphemeBoundary(
                      Int(patchOffset),
                      count: nativeLength,
                      byte: { compatibility[frameAnchor + $0] }
                  ),
                  ReixTextLayout.isGraphemeBoundary(
                      Int(patchOffset + replacedLength),
                      count: nativeLength,
                      byte: { compatibility[frameAnchor + $0] }
                  )
            else { return false }
            localOffset = Int(patchOffset)
            removed = Int(replacedLength)
        }
        let inserted = Int(textLength)
        let nextNativeLength = nativeLength - removed + inserted
        guard Int(cursorOffset) <= nextNativeLength,
              nativeResultValid(
                  count: nextNativeLength,
                  anchor: frameAnchor,
                  offset: localOffset,
                  removed: removed,
                  text0: text0,
                  text0Length: text0Length,
                  text1: text1,
                  text1Length: text1Length,
                  text2: text2,
                  text2Length: text2Length
              ),
              nativeResultBoundary(
                  Int(cursorOffset),
                  count: nextNativeLength,
                  anchor: frameAnchor,
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
                  textLength: nextNativeLength,
                  anchor: frameAnchor,
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

        let resultLength = compatibilityCount - removed + inserted
        nativeAnchor = frameAnchor
        if resultLength > compatibility.count {
            guard trimCompatibility(
                bytes: resultLength - compatibility.count,
                before: nativeAnchor
            ) else { return false }
        }
        let actualOffset = nativeAnchor + localOffset
        guard replaceCompatibility(
            at: actualOffset,
            removed: removed,
            text0: text0,
            text0Length: text0Length,
            text1: text1,
            text1Length: text1Length,
            text2: text2,
            text2Length: text2Length
        ) else { return false }
        self.columns = columns
        self.rows = rows
        nativeLength = nextNativeLength
        nativeActive = true
        compatibilityCursor = nativeAnchor + Int(cursorOffset)

        let snapshot = kind == .snapshot || requiresSnapshot || revision == 0
        let cursor = ReixTextLayout.position(
            at: compatibilityCursor,
            count: compatibilityCount,
            columns: columns,
            byte: { compatibility[$0] }
        )
        let anchor = ReixTextLayout.position(
            at: nativeAnchor,
            count: compatibilityCount,
            columns: columns,
            byte: { compatibility[$0] }
        )
        guard let cursor, let anchor,
              viewportRow <= UInt16.max - anchor.row
        else {
            requiresSnapshot = true
            return false
        }
        let requestedViewport = anchor.row + viewportRow
        let minimumViewport = cursor.row >= viewportRows ? cursor.row - viewportRows + 1 : 0
        let actualViewport = min(cursor.row, max(requestedViewport, minimumViewport))
        return withUnsafeTemporaryAllocation(
            of: ReixTextSurfaceStyleSpan.self,
            capacity: styleCount
        ) { shifted in
            for index in 0..<styleCount {
                let span = styles![index]
                guard span.offset <= UInt32.max - UInt32(nativeAnchor),
                      let translated = ReixTextSurfaceStyleSpan(
                          offset: UInt32(nativeAnchor) + span.offset,
                          length: span.length,
                          role: span.role
                      )
                else { return false }
                shifted[index] = translated
            }
            guard let descriptor = ReixTextSurfaceFrameDescriptor(
                  kind: snapshot ? .snapshot : .patch,
                  correlation: correlation,
                  revision: nextRevision,
                  baseRevision: snapshot ? 0 : revision,
                  patchOffset: snapshot ? 0 : UInt32(actualOffset),
                  replacedLength: snapshot ? 0 : UInt32(removed),
                  textLength: UInt32(snapshot ? compatibilityCount : inserted),
                  styleSpanCount: UInt16(styleCount),
                  columns: columns,
                  rows: rows,
                  cursorRow: cursor.row,
                  cursorColumn: cursor.column,
                  viewportRow: actualViewport,
                  viewportRows: viewportRows
              )
            else { return false }
            let nextTransaction = transaction == UInt32.max ? 1 : transaction + 1
            transaction = nextTransaction
            let presented = compatibility.span.withUnsafeBufferPointer { bytes in
                let sourceOffset = snapshot ? 0 : actualOffset
                let sourceLength = snapshot ? compatibilityCount : inserted
                guard let source = ReixTextSurfaceFrameSource(
                    descriptor: descriptor,
                    text: sourceLength == 0 ? nil : bytes.baseAddress!.advanced(by: sourceOffset),
                    styles: styleCount == 0 ? nil : UnsafePointer(shifted.baseAddress!)
                ) else { return false }
                return sendFrame(source, transaction: nextTransaction)
            }
            if presented {
                revision = nextRevision
                requiresSnapshot = false
            } else {
                requiresSnapshot = true
            }
            return presented
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

    private func nativeResultByte(
        at index: Int,
        count: Int,
        anchor: Int,
        offset: Int,
        removed: Int,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> UInt8? {
        guard index >= 0, index < count else { return nil }
        let inserted = text0Length + text1Length + text2Length
        if index < offset { return compatibility[anchor + index] }
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
        return compatibility[anchor + index - inserted + removed]
    }

    private func nativeResultValid(
        count: Int,
        anchor: Int,
        offset: Int,
        removed: Int,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        ReixTextLayout.validUTF8(count: count) {
            nativeResultByte(
                at: $0,
                count: count,
                anchor: anchor,
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

    private func nativeResultBoundary(
        _ boundary: Int,
        count: Int,
        anchor: Int,
        offset: Int,
        removed: Int,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        ReixTextLayout.isGraphemeBoundary(boundary, count: count) {
            nativeResultByte(
                at: $0,
                count: count,
                anchor: anchor,
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
        anchor: Int,
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
                  nativeResultBoundary(
                      start,
                      count: textLength,
                      anchor: anchor,
                      offset: offset,
                      removed: removed,
                      text0: text0,
                      text0Length: text0Length,
                      text1: text1,
                      text1Length: text1Length,
                      text2: text2,
                      text2Length: text2Length
                  ),
                  nativeResultBoundary(
                      end,
                      count: textLength,
                      anchor: anchor,
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

    private mutating func replaceCompatibility(
        at offset: Int,
        removed: Int,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>?,
        text1Length: Int,
        text2: UnsafePointer<UInt8>?,
        text2Length: Int
    ) -> Bool {
        let inserted = text0Length + text1Length + text2Length
        guard offset >= 0,
              removed >= 0,
              offset <= compatibilityCount,
              removed <= compatibilityCount - offset,
              compatibilityCount - removed <= compatibility.count - inserted
        else { return false }
        let tailStart = offset + removed
        let tailCount = compatibilityCount - tailStart
        if inserted > removed {
            var index = tailCount
            while index > 0 {
                index -= 1
                compatibility[offset + inserted + index] = compatibility[tailStart + index]
            }
        } else if inserted < removed {
            for index in 0..<tailCount {
                compatibility[offset + inserted + index] = compatibility[tailStart + index]
            }
        }
        var destination = offset
        for index in 0..<text0Length { compatibility[destination + index] = text0![index] }
        destination += text0Length
        for index in 0..<text1Length { compatibility[destination + index] = text1![index] }
        destination += text1Length
        for index in 0..<text2Length { compatibility[destination + index] = text2![index] }
        compatibilityCount = compatibilityCount - removed + inserted
        return true
    }

    private mutating func trimCompatibility(bytes required: Int, before protected: Int) -> Bool {
        var cut = 0
        while cut < protected && cut < required {
            while cut < protected && compatibility[cut] != 0x0A { cut += 1 }
            if cut < protected { cut += 1 }
        }
        guard cut >= required, cut <= protected else { return false }
        for index in cut..<compatibilityCount { compatibility[index - cut] = compatibility[index] }
        compatibilityCount -= cut
        compatibilityCursor = max(0, compatibilityCursor - cut)
        nativeAnchor -= cut
        requiresSnapshot = true
        return true
    }

    private mutating func presentCompatibility(
        correlation: UInt32,
        change: CompatibilityChange
    ) -> Bool {
        guard let nextRevision = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision) else {
            usable = false
            return false
        }
        guard let cursor = cursorPosition() else { return false }
        let visibleRows = ReixTextSurfaceFrameDescriptor.interactiveRows(for: rows)
        let viewport = cursor.row >= visibleRows ? cursor.row - visibleRows + 1 : 0
        let snapshot = requiresSnapshot || revision == 0
        guard let descriptor = ReixTextSurfaceFrameDescriptor(
            kind: snapshot ? .snapshot : .patch,
            correlation: correlation,
            revision: nextRevision,
            baseRevision: snapshot ? 0 : revision,
            patchOffset: snapshot ? 0 : UInt32(change.offset),
            replacedLength: snapshot ? 0 : UInt32(change.replaced),
            textLength: UInt32(snapshot ? compatibilityCount : change.inserted),
            columns: columns,
            rows: rows,
            cursorRow: cursor.row,
            cursorColumn: cursor.column,
            viewportRow: viewport,
            viewportRows: visibleRows
        ) else { return false }
        let nextTransaction = transaction == UInt32.max ? 1 : transaction + 1
        transaction = nextTransaction
        let presented = compatibility.span.withUnsafeBufferPointer { bytes in
            let count = snapshot ? compatibilityCount : change.inserted
            let offset = snapshot ? 0 : change.offset
            guard let frame = ReixTextSurfaceFrameSource(
                descriptor: descriptor,
                text: count == 0 ? nil : bytes.baseAddress!.advanced(by: offset)
            ) else { return false }
            return sendFrame(frame, transaction: nextTransaction)
        }
        if presented {
            revision = nextRevision
            requiresSnapshot = false
        } else {
            requiresSnapshot = true
        }
        return presented
    }

    private func sendFrame(_ frame: ReixTextSurfaceFrameSource, transaction: UInt32) -> Bool {
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
              let status = ReixTextSurfaceStatus(rawValue: answer.message.words[0]),
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

    private mutating func apply(_ command: ReixTextSurfaceCommand) -> Bool {
        switch command.kind {
            case .insert:
                return command.text.span.withUnsafeBufferPointer {
                    insert($0.baseAddress!, count: command.count)
                }
            case .eraseBackward:
                for _ in 0..<command.amount where compatibilityCursor > 0 {
                    let start = previousBoundary(before: compatibilityCursor)
                    remove(at: start, count: compatibilityCursor - start)
                    compatibilityCursor = start
                }
                return true
            case .moveLeft:
                for _ in 0..<command.amount where compatibilityCursor > 0 {
                    compatibilityCursor = previousBoundary(before: compatibilityCursor)
                }
                return true
            case .moveRight:
                for _ in 0..<command.amount where compatibilityCursor < compatibilityCount {
                    compatibilityCursor = nextBoundary(after: compatibilityCursor)
                }
                return true
            case .newline:
                compatibilityCursor = compatibilityCount
                var lineFeed: UInt8 = 0x0A
                return withUnsafePointer(to: &lineFeed) { insert($0, count: 1) }
            case .replaceBuffer:
                guard let anchor = compatibilityAnchor(previousRows: command.previousCursorRow) else {
                    return false
                }
                guard command.count <= compatibility.count - anchor else { return false }
                compatibilityCount = anchor
                compatibilityCursor = anchor
                let inserted = command.text.span.withUnsafeBufferPointer {
                    insert($0.baseAddress!, count: command.count)
                }
                guard inserted else { return false }
                let localCursor = byteOffset(
                    row: command.cursorRow,
                    column: command.cursorColumn,
                    from: anchor
                )
                compatibilityCursor = localCursor
                return compatibilityCursor <= compatibilityCount
            case .bell:
                return true
        }
    }

    private func compatibilityChange(for command: ReixTextSurfaceCommand) -> CompatibilityChange? {
        switch command.kind {
            case .insert:
                return CompatibilityChange(offset: compatibilityCursor, replaced: 0, inserted: command.count)
            case .eraseBackward:
                var offset = compatibilityCursor
                for _ in 0..<command.amount where offset > 0 { offset = previousBoundary(before: offset) }
                return CompatibilityChange(
                    offset: offset,
                    replaced: compatibilityCursor - offset,
                    inserted: 0
                )
            case .newline:
                return CompatibilityChange(offset: compatibilityCount, replaced: 0, inserted: 1)
            case .replaceBuffer:
                guard let anchor = compatibilityAnchor(previousRows: command.previousCursorRow) else {
                    return nil
                }
                return CompatibilityChange(
                    offset: anchor,
                    replaced: compatibilityCount - anchor,
                    inserted: command.count
                )
            case .moveLeft, .moveRight, .bell:
                return .metadata
        }
    }

    /// Drops complete rows before the active editor when bounded history fills.
    private mutating func prepareCompatibility(for command: ReixTextSurfaceCommand) -> Bool {
        let protected: Int
        let result: Int
        switch command.kind {
            case .insert:
                protected = rowStart(containing: compatibilityCursor)
                result = compatibilityCount + command.count
            case .newline:
                protected = rowStart(containing: compatibilityCursor)
                result = compatibilityCount + 1
            case .replaceBuffer:
                guard let anchor = compatibilityAnchor(previousRows: command.previousCursorRow) else {
                    return false
                }
                protected = anchor
                result = anchor + command.count
            default:
                return true
        }
        guard result > compatibility.count else { return true }
        let required = result - compatibility.count
        var cut = 0
        while cut < protected && cut < required {
            while cut < protected && compatibility[cut] != 0x0A { cut += 1 }
            if cut < protected { cut += 1 }
        }
        guard cut >= required, cut <= protected else { return false }
        for index in cut..<compatibilityCount { compatibility[index - cut] = compatibility[index] }
        compatibilityCount -= cut
        compatibilityCursor -= cut
        requiresSnapshot = true
        return true
    }

    private func compatibilityAnchor(previousRows: UInt16) -> Int? {
        var anchor = rowStart(containing: compatibilityCursor)
        var remaining = previousRows
        while remaining > 0 {
            guard anchor > 0 else { return nil }
            anchor = rowStart(containing: anchor - 1)
            remaining -= 1
        }
        return anchor
    }

    private func rowStart(containing offset: Int) -> Int {
        var index = min(offset, compatibilityCount)
        while index > 0 && compatibility[index - 1] != 0x0A { index -= 1 }
        return index
    }

    private mutating func insert(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count >= 0, count <= compatibility.count - compatibilityCount else { return false }
        var index = compatibilityCount
        while index > compatibilityCursor {
            index -= 1
            compatibility[index + count] = compatibility[index]
        }
        for offset in 0..<count { compatibility[compatibilityCursor + offset] = bytes[offset] }
        compatibilityCursor += count
        compatibilityCount += count
        return true
    }

    private mutating func remove(at offset: Int, count: Int) {
        for index in (offset + count)..<compatibilityCount {
            compatibility[index - count] = compatibility[index]
        }
        compatibilityCount -= count
    }

    private func previousBoundary(before offset: Int) -> Int {
        ReixTextLayout.previousGraphemeBoundary(before: offset, count: compatibilityCount) {
            compatibility[$0]
        } ?? 0
    }

    private func nextBoundary(after offset: Int) -> Int {
        ReixTextLayout.nextGraphemeBoundary(after: offset, count: compatibilityCount) {
            compatibility[$0]
        } ?? compatibilityCount
    }

    private func byteOffset(row targetRow: UInt16, column targetColumn: UInt16, from start: Int) -> Int {
        let count = compatibilityCount - start
        guard let offset = ReixTextLayout.byteOffset(
            row: targetRow,
            column: targetColumn,
            count: count,
            columns: columns,
            byte: { compatibility[start + $0] }
        ) else { return compatibilityCount + 1 }
        return start + offset
    }

    private func cursorPosition() -> ReixTextLayout.Position? {
        ReixTextLayout.position(
            at: compatibilityCursor,
            count: compatibilityCount,
            columns: columns,
            byte: { compatibility[$0] }
        )
    }

    private struct CompatibilityChange {
        static let metadata = CompatibilityChange(offset: 0, replaced: 0, inserted: 0)

        let offset: Int
        let replaced: Int
        let inserted: Int
    }
}
