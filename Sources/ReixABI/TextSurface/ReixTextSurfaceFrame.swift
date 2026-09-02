//
//  ReixTextSurfaceFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

public enum ReixTextSurfaceFrameKind: UInt16, Equatable {
    case snapshot = 1
    case patch = 2
}

/// Transcript frames flow at the terminal cursor. Editor frames own a bounded viewport.
public enum ReixTextSurfaceFrameMode: UInt16, Equatable {
    case transcript = 1
    case editor = 2
}

public enum ReixTextSurfaceStyleRole: UInt8, Equatable {
    case plain = 0
    case prompt = 1
    case input = 2
    case selection = 3
    case diagnostic = 4
    case overlay = 5
}

/// One semantic style over a UTF-8 byte range.
public struct ReixTextSurfaceStyleSpan: Equatable {
    public static let wireBytes = 8

    public let offset: UInt32
    public let length: UInt16
    public let role: ReixTextSurfaceStyleRole

    public init?(offset: UInt32, length: UInt16, role: ReixTextSurfaceStyleRole) {
        guard length > 0 else { return nil }
        self.offset = offset
        self.length = length
        self.role = role
    }
}

/// Small metadata descriptor. Text and spans stay in caller-owned storage.
public struct ReixTextSurfaceFrameDescriptor: Equatable {
    public static let wireBytes = 64
    public static let maximumTextBytes = 8200
    public static let maximumOverlayBytes = 1024
    public static let maximumStyleSpans: UInt16 = 32
    public static let maximumOverlayStyleSpans: UInt16 = 16
    public static let maximumColumns: UInt16 = 240
    public static let maximumRows: UInt16 = 120

    public let kind: ReixTextSurfaceFrameKind
    public let mode: ReixTextSurfaceFrameMode
    public let correlation: UInt32
    public let revision: UInt32
    public let baseRevision: UInt32
    public let patchOffset: UInt32
    public let replacedLength: UInt32
    public let textLength: UInt32
    public let overlayLength: UInt16
    public let styleSpanCount: UInt16
    public let overlayStyleSpanCount: UInt16
    public let columns: UInt16
    public let rows: UInt16
    public let cursorRow: UInt16
    public let cursorColumn: UInt16
    public let viewportRow: UInt16
    public let viewportRows: UInt16
    public let overlayRow: UInt16
    public let overlayColumn: UInt16
    public let overlayRows: UInt16
    public let overlayColumns: UInt16

    public init?(
        kind: ReixTextSurfaceFrameKind,
        mode: ReixTextSurfaceFrameMode = .editor,
        correlation: UInt32,
        revision: UInt32,
        baseRevision: UInt32,
        patchOffset: UInt32 = 0,
        replacedLength: UInt32 = 0,
        textLength: UInt32,
        overlayLength: UInt16 = 0,
        styleSpanCount: UInt16 = 0,
        overlayStyleSpanCount: UInt16 = 0,
        columns: UInt16,
        rows: UInt16,
        cursorRow: UInt16,
        cursorColumn: UInt16,
        viewportRow: UInt16 = 0,
        viewportRows: UInt16,
        overlayRow: UInt16 = 0,
        overlayColumn: UInt16 = 0,
        overlayRows: UInt16 = 0,
        overlayColumns: UInt16 = 0
    ) {
        guard correlation != 0,
              revision != 0,
              textLength <= UInt32(Self.maximumTextBytes),
              overlayLength <= UInt16(Self.maximumOverlayBytes),
              styleSpanCount <= Self.maximumStyleSpans,
              overlayStyleSpanCount <= Self.maximumOverlayStyleSpans,
              columns > 0,
              columns <= Self.maximumColumns,
              rows > 0,
              rows <= Self.maximumRows,
              cursorColumn < columns,
              viewportRows > 0,
              viewportRows <= Self.interactiveRows(for: rows),
              cursorRow >= viewportRow,
              cursorRow - viewportRow < viewportRows,
              overlayRows <= viewportRows,
              overlayColumns <= columns,
              overlayLength == 0 ? overlayRows == 0 && overlayColumns == 0 : overlayRows > 0 && overlayColumns > 0,
              overlayRows == 0 || overlayRow <= viewportRows - overlayRows,
              overlayColumns == 0 || overlayColumn <= columns - overlayColumns,
              mode == .editor || (
                  viewportRows == 1
                      && viewportRow == cursorRow
                      && overlayLength == 0
              )
        else { return nil }

        switch kind {
            case .snapshot:
                guard baseRevision == 0, patchOffset == 0, replacedLength == 0 else { return nil }
            case .patch:
                guard baseRevision != 0, baseRevision != revision else { return nil }
        }

        self.kind = kind
        self.mode = mode
        self.correlation = correlation
        self.revision = revision
        self.baseRevision = baseRevision
        self.patchOffset = patchOffset
        self.replacedLength = replacedLength
        self.textLength = textLength
        self.overlayLength = overlayLength
        self.styleSpanCount = styleSpanCount
        self.overlayStyleSpanCount = overlayStyleSpanCount
        self.columns = columns
        self.rows = rows
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.viewportRow = viewportRow
        self.viewportRows = viewportRows
        self.overlayRow = overlayRow
        self.overlayColumn = overlayColumn
        self.overlayRows = overlayRows
        self.overlayColumns = overlayColumns
    }

    public var payloadBytes: Int {
        Int(textLength) + Int(styleSpanCount) * ReixTextSurfaceStyleSpan.wireBytes
            + Int(overlayLength) + Int(overlayStyleSpanCount) * ReixTextSurfaceStyleSpan.wireBytes
    }

    public static func interactiveRows(for terminalRows: UInt16) -> UInt16 {
        min(max(UInt16(1), terminalRows / 4), UInt16(15))
    }

    public static func nextRevision(after revision: UInt32) -> UInt32? {
        guard revision != UInt32.max else { return nil }
        return revision + 1
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= Self.wireBytes else { return false }
        for index in 0..<Self.wireBytes { bytes[index] = 0 }
        write16(bytes, 0, kind.rawValue)
        write16(bytes, 2, mode.rawValue)
        write32(bytes, 4, correlation)
        write32(bytes, 8, revision)
        write32(bytes, 12, baseRevision)
        write32(bytes, 16, patchOffset)
        write32(bytes, 20, replacedLength)
        write32(bytes, 24, textLength)
        write16(bytes, 28, overlayLength)
        write16(bytes, 30, styleSpanCount)
        write16(bytes, 32, overlayStyleSpanCount)
        write16(bytes, 34, columns)
        write16(bytes, 36, rows)
        write16(bytes, 38, cursorRow)
        write16(bytes, 40, cursorColumn)
        write16(bytes, 42, viewportRow)
        write16(bytes, 44, viewportRows)
        write16(bytes, 46, overlayRow)
        write16(bytes, 48, overlayColumn)
        write16(bytes, 50, overlayRows)
        write16(bytes, 52, overlayColumns)
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixTextSurfaceFrameDescriptor? {
        guard length == Self.wireBytes,
              let kind = ReixTextSurfaceFrameKind(rawValue: read16(bytes, 0)),
              let mode = ReixTextSurfaceFrameMode(rawValue: read16(bytes, 2)),
              read16(bytes, 54) == 0,
              read32(bytes, 56) == 0,
              read32(bytes, 60) == 0
        else { return nil }
        return ReixTextSurfaceFrameDescriptor(
            kind: kind,
            mode: mode,
            correlation: read32(bytes, 4),
            revision: read32(bytes, 8),
            baseRevision: read32(bytes, 12),
            patchOffset: read32(bytes, 16),
            replacedLength: read32(bytes, 20),
            textLength: read32(bytes, 24),
            overlayLength: read16(bytes, 28),
            styleSpanCount: read16(bytes, 30),
            overlayStyleSpanCount: read16(bytes, 32),
            columns: read16(bytes, 34),
            rows: read16(bytes, 36),
            cursorRow: read16(bytes, 38),
            cursorColumn: read16(bytes, 40),
            viewportRow: read16(bytes, 42),
            viewportRows: read16(bytes, 44),
            overlayRow: read16(bytes, 46),
            overlayColumn: read16(bytes, 48),
            overlayRows: read16(bytes, 50),
            overlayColumns: read16(bytes, 52)
        )
    }
}

/// A producer view. The ring consumes the pointers before push returns.
public struct ReixTextSurfaceFrameSource {
    public let descriptor: ReixTextSurfaceFrameDescriptor
    public let styles: UnsafePointer<ReixTextSurfaceStyleSpan>?
    public let overlay: UnsafePointer<UInt8>?
    public let overlayStyles: UnsafePointer<ReixTextSurfaceStyleSpan>?

    private let text0: UnsafePointer<UInt8>?
    private let text1: UnsafePointer<UInt8>?
    private let text2: UnsafePointer<UInt8>?
    private let text0Length: Int
    private let text1Length: Int
    private let text2Length: Int

    public init?(
        descriptor: ReixTextSurfaceFrameDescriptor,
        text: UnsafePointer<UInt8>?,
        styles: UnsafePointer<ReixTextSurfaceStyleSpan>? = nil,
        overlay: UnsafePointer<UInt8>? = nil,
        overlayStyles: UnsafePointer<ReixTextSurfaceStyleSpan>? = nil
    ) {
        self.init(
            descriptor: descriptor,
            text0: text,
            text0Length: Int(descriptor.textLength),
            text1: nil,
            text1Length: 0,
            text2: nil,
            text2Length: 0,
            styles: styles,
            overlay: overlay,
            overlayStyles: overlayStyles
        )
    }

    public init?(
        descriptor: ReixTextSurfaceFrameDescriptor,
        text0: UnsafePointer<UInt8>?,
        text0Length: Int,
        text1: UnsafePointer<UInt8>? = nil,
        text1Length: Int = 0,
        text2: UnsafePointer<UInt8>? = nil,
        text2Length: Int = 0,
        styles: UnsafePointer<ReixTextSurfaceStyleSpan>? = nil,
        overlay: UnsafePointer<UInt8>? = nil,
        overlayStyles: UnsafePointer<ReixTextSurfaceStyleSpan>? = nil
    ) {
        guard text0Length >= 0,
              text1Length >= 0,
              text2Length >= 0,
              text0Length + text1Length + text2Length == Int(descriptor.textLength),
              (text0Length == 0) == (text0 == nil),
              (text1Length == 0) == (text1 == nil),
              (text2Length == 0) == (text2 == nil),
              (descriptor.styleSpanCount == 0) == (styles == nil),
              (descriptor.overlayLength == 0) == (overlay == nil),
              (descriptor.overlayStyleSpanCount == 0) == (overlayStyles == nil)
        else { return nil }
        self.descriptor = descriptor
        self.text0 = text0
        self.text1 = text1
        self.text2 = text2
        self.text0Length = text0Length
        self.text1Length = text1Length
        self.text2Length = text2Length
        self.styles = styles
        self.overlay = overlay
        self.overlayStyles = overlayStyles
    }

    public func payloadByte(at index: Int) -> UInt8? {
        guard index >= 0, index < descriptor.payloadBytes else { return nil }
        let textEnd = Int(descriptor.textLength)
        if index < textEnd { return textByte(at: index) }
        let styleEnd = textEnd + Int(descriptor.styleSpanCount) * ReixTextSurfaceStyleSpan.wireBytes
        if index < styleEnd {
            return Self.spanByte(
                styles![(index - textEnd) / ReixTextSurfaceStyleSpan.wireBytes],
                byte: (index - textEnd) % ReixTextSurfaceStyleSpan.wireBytes
            )
        }
        let overlayEnd = styleEnd + Int(descriptor.overlayLength)
        if index < overlayEnd { return overlay![index - styleEnd] }
        return Self.spanByte(
            overlayStyles![(index - overlayEnd) / ReixTextSurfaceStyleSpan.wireBytes],
            byte: (index - overlayEnd) % ReixTextSurfaceStyleSpan.wireBytes
        )
    }

    private func textByte(at index: Int) -> UInt8? {
        if index < text0Length { return text0![index] }
        let after0 = index - text0Length
        if after0 < text1Length { return text1![after0] }
        let after1 = after0 - text1Length
        guard after1 < text2Length else { return nil }
        return text2![after1]
    }

    private static func spanByte(_ span: ReixTextSurfaceStyleSpan, byte: Int) -> UInt8 {
        switch byte {
            case 0: return UInt8(truncatingIfNeeded: span.offset)
            case 1: return UInt8(truncatingIfNeeded: span.offset >> 8)
            case 2: return UInt8(truncatingIfNeeded: span.offset >> 16)
            case 3: return UInt8(truncatingIfNeeded: span.offset >> 24)
            case 4: return UInt8(truncatingIfNeeded: span.length)
            case 5: return UInt8(truncatingIfNeeded: span.length >> 8)
            case 6: return span.role.rawValue
            default: return 0
        }
    }
}

public enum ReixTextSurfaceRecordKind: UInt16, Equatable {
    case begin = 1
    case chunk = 2
    case end = 3
}

/// One bounded record of a transaction. Only this envelope enters the ring.
public struct ReixTextSurfaceFrameRecord: Equatable {
    public static let payloadBytes = 256

    public let kind: ReixTextSurfaceRecordKind
    public let transaction: UInt32
    public let chunk: UInt16
    public let chunks: UInt16
    public let checksum: UInt32
    public let count: Int
    public let payload: InlineArray<256, UInt8>

    public init?(
        kind: ReixTextSurfaceRecordKind,
        transaction: UInt32,
        chunk: UInt16,
        chunks: UInt16,
        checksum: UInt32,
        bytes: UnsafePointer<UInt8>? = nil,
        count: Int = 0
    ) {
        var payload = InlineArray<256, UInt8>(repeating: 0)
        guard transaction != 0,
              chunks >= 2,
              chunk < chunks,
              checksum != 0,
              count >= 0,
              count <= Self.payloadBytes,
              (count == 0) == (bytes == nil)
        else { return nil }
        if count > 0 {
            guard let bytes else { return nil }
            for index in 0..<count { payload[index] = bytes[index] }
        }
        self.kind = kind
        self.transaction = transaction
        self.chunk = chunk
        self.chunks = chunks
        self.checksum = checksum
        self.count = count
        self.payload = payload
        guard valid() else { return nil }
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Bool {
        guard capacity >= ReixTextSurfaceProtocol.recordBytes, valid() else { return false }
        for index in 0..<ReixTextSurfaceProtocol.recordBytes { bytes[index] = 0 }
        write16(bytes, 0, ReixTextSurfaceProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write16(bytes, 4, UInt16(count))
        write16(bytes, 6, 0)
        write32(bytes, 8, transaction)
        write16(bytes, 12, chunk)
        write16(bytes, 14, chunks)
        write32(bytes, 16, checksum)
        for index in 0..<count { bytes[ReixTextSurfaceProtocol.headerBytes + index] = payload[index] }
        return true
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> ReixTextSurfaceFrameRecord? {
        guard length == ReixTextSurfaceProtocol.recordBytes,
              read16(bytes, 0) == ReixTextSurfaceProtocol.version,
              let kind = ReixTextSurfaceRecordKind(rawValue: read16(bytes, 2)),
              read16(bytes, 6) == 0,
              read32(bytes, 20) == 0,
              read32(bytes, 24) == 0,
              read32(bytes, 28) == 0
        else { return nil }
        let count = Int(read16(bytes, 4))
        guard count <= Self.payloadBytes,
              zero(bytes, from: ReixTextSurfaceProtocol.headerBytes + count, through: length)
        else { return nil }
        return ReixTextSurfaceFrameRecord(
            kind: kind,
            transaction: read32(bytes, 8),
            chunk: read16(bytes, 12),
            chunks: read16(bytes, 14),
            checksum: read32(bytes, 16),
            bytes: count == 0 ? nil : bytes + ReixTextSurfaceProtocol.headerBytes,
            count: count
        )
    }

    private func valid() -> Bool {
        switch kind {
            case .begin: return chunk == 0 && count == ReixTextSurfaceFrameDescriptor.wireBytes
            case .chunk: return chunk > 0 && chunk + 1 < chunks && count > 0
            case .end: return chunk + 1 == chunks && count == 0
        }
    }

    public static func == (lhs: ReixTextSurfaceFrameRecord, rhs: ReixTextSurfaceFrameRecord) -> Bool {
        guard lhs.kind == rhs.kind,
              lhs.transaction == rhs.transaction,
              lhs.chunk == rhs.chunk,
              lhs.chunks == rhs.chunks,
              lhs.checksum == rhs.checksum,
              lhs.count == rhs.count
        else { return false }
        for index in 0..<lhs.count where lhs.payload[index] != rhs.payload[index] { return false }
        return true
    }

    private static func zero(_ bytes: UnsafePointer<UInt8>, from: Int, through: Int) -> Bool {
        for index in from..<through where bytes[index] != 0 { return false }
        return true
    }
}
