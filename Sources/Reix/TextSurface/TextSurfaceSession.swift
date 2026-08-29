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
    private var compatibility = InlineArray<8192, UInt8>(repeating: 0)
    private var compatibilityCount = 0
    private var compatibilityCursor = 0
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
              prepareCompatibility(for: command),
              let change = compatibilityChange(for: command),
              apply(command)
        else { return false }
        return presentCompatibility(correlation: command.sequence, change: change)
    }

    public mutating func resize(width: UInt16, height: UInt16, correlation: UInt32) -> Bool {
        guard width > 0,
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

    private mutating func presentCompatibility(
        correlation: UInt32,
        change: CompatibilityChange
    ) -> Bool {
        guard let nextRevision = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision) else {
            usable = false
            return false
        }
        let cursor = cursorPosition()
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
        var index = offset - 1
        while index > 0 && compatibility[index] & 0xC0 == 0x80 { index -= 1 }
        return index
    }

    private func nextBoundary(after offset: Int) -> Int {
        var index = offset + 1
        while index < compatibilityCount && compatibility[index] & 0xC0 == 0x80 { index += 1 }
        return index
    }

    private func byteOffset(row targetRow: UInt16, column targetColumn: UInt16, from start: Int) -> Int {
        var row: UInt16 = 0
        var column: UInt16 = 0
        for index in start..<compatibilityCount {
            if row == targetRow && column == targetColumn { return index }
            let byte = compatibility[index]
            if byte == 0x0A { row &+= 1; column = 0 }
            else if byte & 0xC0 != 0x80 { column &+= 1 }
        }
        return row == targetRow && column == targetColumn ? compatibilityCount : compatibilityCount + 1
    }

    private func cursorPosition() -> (row: UInt16, column: UInt16) {
        var row: UInt16 = 0
        var column: UInt16 = 0
        for index in 0..<compatibilityCursor {
            let byte = compatibility[index]
            if byte == 0x0A { row &+= 1; column = 0 }
            else if byte & 0xC0 != 0x80 {
                column &+= 1
                if column == columns { row &+= 1; column = 0 }
            }
        }
        return (row, column)
    }

    private struct CompatibilityChange {
        static let metadata = CompatibilityChange(offset: 0, replaced: 0, inserted: 0)

        let offset: Int
        let replaced: Int
        let inserted: Int
    }
}
