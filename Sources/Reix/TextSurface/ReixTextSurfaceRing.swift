//
//  ReixTextSurfaceRing.swift
//  ReixOS
//

import ReixABI

public enum ReixTextSurfacePopResult: Equatable {
    case empty
    case incomplete
    case malformed
    case stale
    case committed
    case retry
}

public enum ReixTextSurfaceConsumeDisposition {
    case commit
    case retry
}

/// A validated view into one still-unconsumed ring transaction.
public struct ReixTextSurfaceFrameView {
    public let transaction: UInt32
    public let checksum: UInt32
    public let descriptor: ReixTextSurfaceFrameDescriptor

    private let page: UnsafeMutablePointer<UInt8>
    private let firstRecord: UInt32
    private let capacity: Int

    fileprivate init(
        page: UnsafeMutablePointer<UInt8>,
        firstRecord: UInt32,
        capacity: Int,
        transaction: UInt32,
        checksum: UInt32,
        descriptor: ReixTextSurfaceFrameDescriptor
    ) {
        self.page = page
        self.firstRecord = firstRecord
        self.capacity = capacity
        self.transaction = transaction
        self.checksum = checksum
        self.descriptor = descriptor
    }

    public func textByte(at index: Int) -> UInt8? {
        guard index >= 0, index < Int(descriptor.textLength) else { return nil }
        return payloadByte(at: index)
    }

    public func overlayByte(at index: Int) -> UInt8? {
        guard index >= 0, index < Int(descriptor.overlayLength) else { return nil }
        let offset = Int(descriptor.textLength)
            + Int(descriptor.styleSpanCount) * ReixTextSurfaceStyleSpan.wireBytes
        return payloadByte(at: offset + index)
    }

    public func styleSpan(at index: Int) -> ReixTextSurfaceStyleSpan? {
        guard index >= 0, index < Int(descriptor.styleSpanCount) else { return nil }
        return span(at: Int(descriptor.textLength) + index * ReixTextSurfaceStyleSpan.wireBytes)
    }

    public func overlayStyleSpan(at index: Int) -> ReixTextSurfaceStyleSpan? {
        guard index >= 0, index < Int(descriptor.overlayStyleSpanCount) else { return nil }
        let offset = Int(descriptor.textLength)
            + Int(descriptor.styleSpanCount) * ReixTextSurfaceStyleSpan.wireBytes
            + Int(descriptor.overlayLength)
        return span(at: offset + index * ReixTextSurfaceStyleSpan.wireBytes)
    }

    private func span(at offset: Int) -> ReixTextSurfaceStyleSpan? {
        guard let b0 = payloadByte(at: offset),
              let b1 = payloadByte(at: offset + 1),
              let b2 = payloadByte(at: offset + 2),
              let b3 = payloadByte(at: offset + 3),
              let b4 = payloadByte(at: offset + 4),
              let b5 = payloadByte(at: offset + 5),
              let roleByte = payloadByte(at: offset + 6),
              payloadByte(at: offset + 7) == 0,
              let role = ReixTextSurfaceStyleRole(rawValue: roleByte)
        else { return nil }
        let rangeOffset = UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
        let length = UInt16(b4) | UInt16(b5) << 8
        return ReixTextSurfaceStyleSpan(offset: rangeOffset, length: length, role: role)
    }

    private func payloadByte(at index: Int) -> UInt8? {
        guard index >= 0, index < descriptor.payloadBytes else { return nil }
        let record = 1 + index / ReixTextSurfaceFrameRecord.payloadBytes
        let slot = Int((firstRecord &+ UInt32(record)) % UInt32(capacity))
        let address = page.advanced(
            by: ReixTextSurfaceTransport.headerBytes + slot * ReixTextSurfaceProtocol.recordBytes
                + ReixTextSurfaceProtocol.headerBytes
        )
        return address[index % ReixTextSurfaceFrameRecord.payloadBytes]
    }
}

/// One SPSC region for atomic semantic TextSurface frame transactions.
public struct ReixTextSurfaceRing {
    private static let producerOffset = 28
    private static let consumerOffset = 32
    private static let ackStatusOffset = 40
    private static let ackTransactionOffset = 44
    private static let ackRevisionOffset = 48
    private static let ackBaseRevisionOffset = 52

    private let page: UnsafeMutablePointer<UInt8>
    private let expectedToken: UInt32
    private let expectedEpoch: UInt64

    public init?(page: UnsafeMutablePointer<UInt8>, token: UInt32, epoch: UInt64) {
        guard token != 0, epoch != 0, Self.snapshot(page: page, token: token, epoch: epoch) != nil else {
            return nil
        }
        self.page = page
        self.expectedToken = token
        self.expectedEpoch = epoch
    }

    public static func initialize(page: UnsafeMutablePointer<UInt8>, token: UInt32) -> Bool {
        guard let header = ReixTextSurfaceRingHeader.proposal(token: token) else { return false }
        for index in 0..<ReixTextSurfaceTransport.regionBytes { page[index] = 0 }
        return header.encode(into: page, capacity: ReixTextSurfaceTransport.headerBytes)
    }

    public static func accept(page: UnsafeMutablePointer<UInt8>, token: UInt32, epoch: UInt64) -> Bool {
        let producer = loadCursor(page, offset: producerOffset)
        let consumer = loadCursor(page, offset: consumerOffset)
        guard let proposal = ReixTextSurfaceRingHeader.decode(
            UnsafePointer(page),
            length: ReixTextSurfaceTransport.headerBytes,
            producer: producer,
            consumer: consumer
        ),
              proposal.token == token,
              proposal.state == .proposed,
              proposal.producer == 0,
              proposal.consumer == 0,
              let accepted = proposal.accepted(epoch: epoch)
        else { return false }
        return accepted.encode(into: page, capacity: ReixTextSurfaceTransport.headerBytes)
    }

    /// Writes every record before publishing the producer cursor once.
    public func push(transaction: UInt32, frame: ReixTextSurfaceFrameSource) -> Bool {
        guard transaction != 0, let header = header() else { return false }
        let dataRecords = (frame.descriptor.payloadBytes + ReixTextSurfaceFrameRecord.payloadBytes - 1)
            / ReixTextSurfaceFrameRecord.payloadBytes
        let records = dataRecords + 2
        let available = UInt32(header.capacity) - (header.producer &- header.consumer)
        guard records <= ReixTextSurfaceTransport.maximumFrameRecords,
              UInt32(records) <= available,
              let checksum = checksum(frame)
        else { return false }

        var descriptorBytes = InlineArray<64, UInt8>(repeating: 0)
        let encoded = withUnsafeMutableBytes(of: &descriptorBytes) {
            frame.descriptor.encode(
                into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self),
                capacity: $0.count
            )
        }
        guard encoded else { return false }
        let chunks = UInt16(records)
        let begin = descriptorBytes.span.withUnsafeBufferPointer {
            ReixTextSurfaceFrameRecord(
                kind: .begin,
                transaction: transaction,
                chunk: 0,
                chunks: chunks,
                checksum: checksum,
                bytes: $0.baseAddress!,
                count: $0.count
            )
        }
        guard let begin, write(begin, at: header.producer, header: header) else { return false }

        var payloadOffset = 0
        for recordIndex in 1..<(records - 1) {
            let count = min(ReixTextSurfaceFrameRecord.payloadBytes, frame.descriptor.payloadBytes - payloadOffset)
            var payload = InlineArray<256, UInt8>(repeating: 0)
            for index in 0..<count {
                guard let byte = frame.payloadByte(at: payloadOffset + index) else { return false }
                payload[index] = byte
            }
            let record = payload.span.withUnsafeBufferPointer {
                ReixTextSurfaceFrameRecord(
                    kind: .chunk,
                    transaction: transaction,
                    chunk: UInt16(recordIndex),
                    chunks: chunks,
                    checksum: checksum,
                    bytes: $0.baseAddress!,
                    count: count
                )
            }
            guard let record,
                  write(record, at: header.producer &+ UInt32(recordIndex), header: header)
            else { return false }
            payloadOffset += count
        }

        guard let end = ReixTextSurfaceFrameRecord(
            kind: .end,
            transaction: transaction,
            chunk: chunks - 1,
            chunks: chunks,
            checksum: checksum
        ),
              write(end, at: header.producer &+ UInt32(records - 1), header: header)
        else { return false }
        dmbISH()
        Self.storeCursor(page, offset: Self.producerOffset, value: header.producer &+ UInt32(records))
        return true
    }

    /// Validates the complete batch before the consumer can commit it.
    public func popFrame(
        transaction: UInt32,
        _ consume: (ReixTextSurfaceFrameView) -> ReixTextSurfaceConsumeDisposition
    ) -> ReixTextSurfacePopResult {
        guard transaction != 0, let header = header() else { return .malformed }
        guard header.producer != header.consumer else { return .empty }
        dmbISH()
        guard let begin = read(at: header.consumer, header: header) else { return .malformed }
        guard begin.kind == .begin else { return .malformed }
        guard begin.transaction == transaction else { return .stale }
        guard Int(begin.chunks) <= Int(header.capacity) else { return .malformed }
        guard UInt32(begin.chunks) <= header.producer &- header.consumer else { return .incomplete }

        let descriptor = begin.payload.span.withUnsafeBufferPointer {
            ReixTextSurfaceFrameDescriptor.decode($0.baseAddress!, length: ReixTextSurfaceFrameDescriptor.wireBytes)
        }
        guard let descriptor else { return .malformed }
        let dataRecords = (descriptor.payloadBytes + ReixTextSurfaceFrameRecord.payloadBytes - 1)
            / ReixTextSurfaceFrameRecord.payloadBytes
        guard Int(begin.chunks) == dataRecords + 2 else { return .malformed }

        var hash = Self.hashStart
        for index in 0..<begin.count { hash = Self.hash(hash, begin.payload[index]) }
        var payloadCount = 0
        for index in 1..<(Int(begin.chunks) - 1) {
            guard let chunk = read(at: header.consumer &+ UInt32(index), header: header),
                  chunk.kind == .chunk,
                  chunk.transaction == transaction,
                  chunk.chunk == UInt16(index),
                  chunk.chunks == begin.chunks,
                  chunk.checksum == begin.checksum,
                  chunk.count == min(
                      ReixTextSurfaceFrameRecord.payloadBytes,
                      descriptor.payloadBytes - payloadCount
                  )
            else { return .malformed }
            for byte in 0..<chunk.count { hash = Self.hash(hash, chunk.payload[byte]) }
            payloadCount += chunk.count
        }
        guard payloadCount == descriptor.payloadBytes,
              let end = read(at: header.consumer &+ UInt32(begin.chunks - 1), header: header),
              end.kind == .end,
              end.transaction == transaction,
              end.chunk + 1 == begin.chunks,
              end.chunks == begin.chunks,
              end.checksum == begin.checksum,
              Self.nonzero(hash) == begin.checksum
        else { return .malformed }

        let view = ReixTextSurfaceFrameView(
            page: page,
            firstRecord: header.consumer,
            capacity: Int(header.capacity),
            transaction: transaction,
            checksum: begin.checksum,
            descriptor: descriptor
        )
        guard validPayload(view) else { return .malformed }
        guard consume(view) == .commit else { return .retry }
        dmbISH()
        Self.storeCursor(page, offset: Self.consumerOffset, value: header.consumer &+ UInt32(begin.chunks))
        return .committed
    }

    /// Recovery is explicit because malformed records are not valid consumption.
    public func recoverMalformed() -> Bool {
        guard let header = header(), header.consumer != header.producer else { return false }
        dmbISH()
        Self.storeCursor(page, offset: Self.consumerOffset, value: header.producer)
        return true
    }

    public func publish(_ acknowledgement: ReixTextSurfaceAcknowledgement) -> Bool {
        guard acknowledgement.token == expectedToken,
              acknowledgement.epoch == expectedEpoch,
              header() != nil
        else { return false }
        Self.storeCursor(page, offset: Self.ackStatusOffset, value: ReixTextSurfaceAckStatus.pending.rawValue)
        dmbISH()
        Self.storeCursor(page, offset: Self.ackTransactionOffset, value: 0)
        Self.storeCursor(page, offset: Self.ackRevisionOffset, value: 0)
        Self.storeCursor(page, offset: Self.ackBaseRevisionOffset, value: 0)
        dmbISH()
        Self.storeCursor(page, offset: Self.ackTransactionOffset, value: acknowledgement.transaction)
        Self.storeCursor(page, offset: Self.ackRevisionOffset, value: acknowledgement.revision)
        Self.storeCursor(page, offset: Self.ackBaseRevisionOffset, value: acknowledgement.baseRevision)
        dmbISH()
        Self.storeCursor(page, offset: Self.ackStatusOffset, value: acknowledgement.status.rawValue)
        return true
    }

    public func acknowledgement(transaction: UInt32) -> ReixTextSurfaceAcknowledgement? {
        guard let header = header() else { return nil }
        let statusRaw = Self.loadCursor(page, offset: Self.ackStatusOffset)
        dmbISH()
        guard let status = ReixTextSurfaceAckStatus(rawValue: statusRaw),
              status != .pending,
              Self.loadCursor(page, offset: Self.ackTransactionOffset) == transaction
        else { return nil }
        return ReixTextSurfaceAcknowledgement(
            status: status,
            transaction: transaction,
            revision: Self.loadCursor(page, offset: Self.ackRevisionOffset),
            baseRevision: Self.loadCursor(page, offset: Self.ackBaseRevisionOffset),
            token: header.token,
            epoch: header.epoch
        )
    }

    private func validPayload(_ view: ReixTextSurfaceFrameView) -> Bool {
        guard validUTF8(count: Int(view.descriptor.textLength), byte: view.textByte),
              validUTF8(count: Int(view.descriptor.overlayLength), byte: view.overlayByte),
              validSpans(
                  count: Int(view.descriptor.styleSpanCount),
                  limit: view.descriptor.kind == .snapshot
                      ? view.descriptor.textLength
                      : UInt32(ReixTextSurfaceFrameDescriptor.maximumTextBytes),
                  span: view.styleSpan
              ),
              validSpans(
                  count: Int(view.descriptor.overlayStyleSpanCount),
                  limit: UInt32(view.descriptor.overlayLength),
                  span: view.overlayStyleSpan
              )
        else { return false }
        return true
    }

    private func validSpans(
        count: Int,
        limit: UInt32,
        span: (Int) -> ReixTextSurfaceStyleSpan?
    ) -> Bool {
        var previousEnd: UInt32 = 0
        for index in 0..<count {
            guard let item = span(index) else { return false }
            let end = UInt64(item.offset) + UInt64(item.length)
            guard item.offset >= previousEnd, end <= UInt64(limit) else { return false }
            previousEnd = UInt32(end)
        }
        return true
    }

    private func validUTF8(count: Int, byte: (Int) -> UInt8?) -> Bool {
        ReixTextLayout.validUTF8(count: count, byte: byte)
    }

    private func write(
        _ record: ReixTextSurfaceFrameRecord,
        at cursor: UInt32,
        header: ReixTextSurfaceRingHeader
    ) -> Bool {
        let slot = Int(cursor % UInt32(header.capacity))
        let address = page.advanced(by: ReixTextSurfaceTransport.headerBytes + slot * Int(header.recordBytes))
        return record.encode(into: address, capacity: Int(header.recordBytes))
    }

    private func read(
        at cursor: UInt32,
        header: ReixTextSurfaceRingHeader
    ) -> ReixTextSurfaceFrameRecord? {
        let slot = Int(cursor % UInt32(header.capacity))
        let address = page.advanced(by: ReixTextSurfaceTransport.headerBytes + slot * Int(header.recordBytes))
        return ReixTextSurfaceFrameRecord.decode(UnsafePointer(address), length: Int(header.recordBytes))
    }

    private func checksum(_ frame: ReixTextSurfaceFrameSource) -> UInt32? {
        var descriptor = InlineArray<64, UInt8>(repeating: 0)
        guard withUnsafeMutableBytes(of: &descriptor, {
            frame.descriptor.encode(
                into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self),
                capacity: $0.count
            )
        }) else { return nil }
        var value = Self.hashStart
        for index in 0..<descriptor.count { value = Self.hash(value, descriptor[index]) }
        for index in 0..<frame.descriptor.payloadBytes {
            guard let byte = frame.payloadByte(at: index) else { return nil }
            value = Self.hash(value, byte)
        }
        return Self.nonzero(value)
    }

    private func header() -> ReixTextSurfaceRingHeader? {
        Self.snapshot(page: page, token: expectedToken, epoch: expectedEpoch)
    }

    private static func snapshot(
        page: UnsafeMutablePointer<UInt8>,
        token: UInt32,
        epoch: UInt64
    ) -> ReixTextSurfaceRingHeader? {
        let producer = loadCursor(page, offset: producerOffset)
        let consumer = loadCursor(page, offset: consumerOffset)
        guard let header = ReixTextSurfaceRingHeader.decode(
            UnsafePointer(page),
            length: ReixTextSurfaceTransport.headerBytes,
            producer: producer,
            consumer: consumer
        ),
              header.features == ReixTextSurfaceTransport.supportedFeatures,
              header.state == .accepted,
              header.token == token,
              header.epoch == epoch,
              header.producer &- header.consumer <= UInt32(header.capacity)
        else { return nil }
        return header
    }

    private static let hashStart: UInt32 = 2_166_136_261

    private static func hash(_ value: UInt32, _ byte: UInt8) -> UInt32 {
        (value ^ UInt32(byte)) &* 16_777_619
    }

    private static func nonzero(_ value: UInt32) -> UInt32 {
        value == 0 ? 1 : value
    }

    @inline(__always)
    private static func loadCursor(_ page: UnsafeMutablePointer<UInt8>, offset: Int) -> UInt32 {
        UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self).pointee
    }

    @inline(__always)
    private static func storeCursor(_ page: UnsafeMutablePointer<UInt8>, offset: Int, value: UInt32) {
        UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self).pointee = value
    }
}
