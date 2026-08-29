//
//  TextSurfaceScreenModel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

/// Bounded UTF-8 state for the interactive quarter and its separate overlay.
public struct TextSurfaceScreenModel {
    public enum ApplyResult: Equatable {
        case ready
        case duplicate
        case resynchronizationRequired
    }

    public private(set) var columns: UInt16 = 1
    public private(set) var rows: UInt16 = 1
    public private(set) var cursorRow: UInt16 = 0
    public private(set) var cursorColumn: UInt16 = 0
    public private(set) var viewportRow: UInt16 = 0
    public private(set) var viewportRows: UInt16 = 1
    public private(set) var overlayRow: UInt16 = 0
    public private(set) var overlayColumn: UInt16 = 0
    public private(set) var overlayRows: UInt16 = 0
    public private(set) var overlayColumns: UInt16 = 0
    public private(set) var revision: UInt32 = 0
    public private(set) var requiresResynchronization = false
    public private(set) var textLength = 0
    public private(set) var overlayLength = 0
    public private(set) var styleSpanCount = 0
    public private(set) var overlayStyleSpanCount = 0

    private var text = InlineArray<8192, UInt8>(repeating: 0)
    private var overlay = InlineArray<1024, UInt8>(repeating: 0)
    private var styles = InlineArray<32, ReixTextSurfaceStyleSpan>(
        repeating: ReixTextSurfaceStyleSpan(offset: 0, length: 1, role: .plain)!
    )
    private var overlayStyles = InlineArray<16, ReixTextSurfaceStyleSpan>(
        repeating: ReixTextSurfaceStyleSpan(offset: 0, length: 1, role: .plain)!
    )
    private var committedChecksum: UInt32 = 0

    public init() {}

    public var interactiveRows: UInt16 {
        ReixTextSurfaceFrameDescriptor.interactiveRows(for: rows)
    }

    public func textByte(at index: Int) -> UInt8? {
        guard index >= 0, index < textLength else { return nil }
        return text[index]
    }

    public func overlayByte(at index: Int) -> UInt8? {
        guard index >= 0, index < overlayLength else { return nil }
        return overlay[index]
    }

    public func styleSpan(at index: Int) -> ReixTextSurfaceStyleSpan? {
        guard index >= 0, index < styleSpanCount else { return nil }
        return styles[index]
    }

    public func overlayStyleSpan(at index: Int) -> ReixTextSurfaceStyleSpan? {
        guard index >= 0, index < overlayStyleSpanCount else { return nil }
        return overlayStyles[index]
    }

    public mutating func prepare(_ frame: ReixTextSurfaceFrameView) -> ApplyResult {
        if frame.descriptor.revision == revision {
            guard frame.checksum == committedChecksum else {
                requiresResynchronization = true
                return .resynchronizationRequired
            }
            return .duplicate
        }
        guard accepts(frame), valid(frame) else {
            requiresResynchronization = true
            return .resynchronizationRequired
        }
        return .ready
    }

    public mutating func commit(_ frame: ReixTextSurfaceFrameView) -> Bool {
        guard prepare(frame) == .ready else { return false }
        let descriptor = frame.descriptor
        if descriptor.kind == .snapshot {
            textLength = Int(descriptor.textLength)
            for index in 0..<textLength { text[index] = frame.textByte(at: index)! }
        } else {
            let offset = Int(descriptor.patchOffset)
            let removed = Int(descriptor.replacedLength)
            let inserted = Int(descriptor.textLength)
            let tailStart = offset + removed
            let tailCount = textLength - tailStart
            if inserted > removed {
                var index = tailCount
                while index > 0 {
                    index -= 1
                    text[offset + inserted + index] = text[tailStart + index]
                }
            } else if inserted < removed {
                for index in 0..<tailCount { text[offset + inserted + index] = text[tailStart + index] }
            }
            for index in 0..<inserted { text[offset + index] = frame.textByte(at: index)! }
            textLength = textLength - removed + inserted
        }

        styleSpanCount = Int(descriptor.styleSpanCount)
        for index in 0..<styleSpanCount { styles[index] = frame.styleSpan(at: index)! }
        overlayLength = Int(descriptor.overlayLength)
        for index in 0..<overlayLength { overlay[index] = frame.overlayByte(at: index)! }
        overlayStyleSpanCount = Int(descriptor.overlayStyleSpanCount)
        for index in 0..<overlayStyleSpanCount {
            overlayStyles[index] = frame.overlayStyleSpan(at: index)!
        }
        columns = descriptor.columns
        rows = descriptor.rows
        cursorRow = descriptor.cursorRow
        cursorColumn = descriptor.cursorColumn
        viewportRow = descriptor.viewportRow
        viewportRows = descriptor.viewportRows
        overlayRow = descriptor.overlayRow
        overlayColumn = descriptor.overlayColumn
        overlayRows = descriptor.overlayRows
        overlayColumns = descriptor.overlayColumns
        revision = descriptor.revision
        committedChecksum = frame.checksum
        requiresResynchronization = false
        return true
    }

    public mutating func requireSnapshot() {
        requiresResynchronization = true
    }

    public func desiredTextLength(for frame: ReixTextSurfaceFrameView) -> Int {
        if frame.descriptor.kind == .snapshot { return Int(frame.descriptor.textLength) }
        return textLength - Int(frame.descriptor.replacedLength) + Int(frame.descriptor.textLength)
    }

    public func desiredTextByte(at index: Int, for frame: ReixTextSurfaceFrameView) -> UInt8? {
        guard index >= 0, index < desiredTextLength(for: frame) else { return nil }
        if frame.descriptor.kind == .snapshot { return frame.textByte(at: index) }
        let offset = Int(frame.descriptor.patchOffset)
        let inserted = Int(frame.descriptor.textLength)
        if index < offset { return text[index] }
        if index < offset + inserted { return frame.textByte(at: index - offset) }
        return text[index - inserted + Int(frame.descriptor.replacedLength)]
    }

    private func accepts(_ frame: ReixTextSurfaceFrameView) -> Bool {
        guard let expected = ReixTextSurfaceFrameDescriptor.nextRevision(after: revision),
              frame.descriptor.revision == expected
        else { return false }
        if frame.descriptor.kind == .snapshot {
            return frame.descriptor.baseRevision == 0
        }
        return !requiresResynchronization && revision != 0 && frame.descriptor.baseRevision == revision
    }

    private func valid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor = frame.descriptor
        if descriptor.kind == .patch {
            guard descriptor.columns == columns,
                  descriptor.rows == rows,
                  Int(descriptor.patchOffset) <= textLength,
                  Int(descriptor.replacedLength) <= textLength - Int(descriptor.patchOffset),
                  boundary(Int(descriptor.patchOffset)),
                  boundary(Int(descriptor.patchOffset + descriptor.replacedLength))
            else { return false }
        }
        let resultLength = desiredTextLength(for: frame)
        guard resultLength >= 0,
              resultLength <= ReixTextSurfaceFrameDescriptor.maximumTextBytes,
              spansValid(frame, count: Int(descriptor.styleSpanCount), limit: resultLength, overlay: false),
              spansValid(
                  frame,
                  count: Int(descriptor.overlayStyleSpanCount),
                  limit: Int(descriptor.overlayLength),
                  overlay: true
              ),
              overlayValid(frame),
              cursorValid(frame)
        else { return false }
        return true
    }

    private func boundary(_ index: Int) -> Bool {
        index == 0 || index == textLength || text[index] & 0xC0 != 0x80
    }

    private func spansValid(
        _ frame: ReixTextSurfaceFrameView,
        count: Int,
        limit: Int,
        overlay: Bool
    ) -> Bool {
        var previousEnd = 0
        for index in 0..<count {
            let span = overlay ? frame.overlayStyleSpan(at: index) : frame.styleSpan(at: index)
            guard let span else { return false }
            let end = Int(span.offset) + Int(span.length)
            let startBoundary = overlay
                ? overlayBoundary(Int(span.offset), frame: frame)
                : desiredBoundary(Int(span.offset), frame: frame)
            let endBoundary = overlay
                ? overlayBoundary(end, frame: frame)
                : desiredBoundary(end, frame: frame)
            guard Int(span.offset) >= previousEnd,
                  end <= limit,
                  startBoundary,
                  endBoundary
            else { return false }
            previousEnd = end
        }
        return true
    }

    private func desiredBoundary(_ index: Int, frame: ReixTextSurfaceFrameView) -> Bool {
        let length = desiredTextLength(for: frame)
        guard index >= 0, index <= length else { return false }
        return index == 0 || index == length || desiredTextByte(at: index, for: frame)! & 0xC0 != 0x80
    }

    private func overlayBoundary(_ index: Int, frame: ReixTextSurfaceFrameView) -> Bool {
        let length = Int(frame.descriptor.overlayLength)
        guard index >= 0, index <= length else { return false }
        return index == 0 || index == length || frame.overlayByte(at: index)! & 0xC0 != 0x80
    }

    private func overlayValid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor = frame.descriptor
        guard descriptor.overlayLength > 0 else { return true }
        var row: UInt16 = 0
        var column: UInt16 = 0
        for index in 0..<Int(descriptor.overlayLength) {
            guard row < descriptor.overlayRows,
                  let byte = frame.overlayByte(at: index)
            else { return false }
            if byte == 0x0A {
                row &+= 1
                column = 0
            } else if byte & 0xC0 != 0x80 {
                column &+= 1
                if column == descriptor.overlayColumns { row &+= 1; column = 0 }
            }
        }
        return row < descriptor.overlayRows || row == descriptor.overlayRows && column == 0
    }

    private func cursorValid(_ frame: ReixTextSurfaceFrameView) -> Bool {
        let descriptor = frame.descriptor
        var row: UInt16 = 0
        var column: UInt16 = 0
        var index = 0
        while index < desiredTextLength(for: frame) {
            if row == descriptor.cursorRow && column == descriptor.cursorColumn { return true }
            guard let byte = desiredTextByte(at: index, for: frame) else { return false }
            if byte == 0x0A {
                row &+= 1
                column = 0
                index += 1
                continue
            }
            if byte & 0xC0 != 0x80 {
                column &+= 1
                if column == descriptor.columns { row &+= 1; column = 0 }
            }
            index += 1
        }
        return row == descriptor.cursorRow && column == descriptor.cursorColumn
    }
}
