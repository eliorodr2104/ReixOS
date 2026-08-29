//
//  ReixTextSurfaceRing.swift
//  ReixOS
//

import ReixABI

/// One SPSC page for semantic TextSurface commands.
public struct ReixTextSurfaceRing {
    private static let producerOffset = 28
    private static let consumerOffset = 32

    private let page: UnsafeMutablePointer<UInt8>
    private let expectedToken: UInt32
    private let expectedEpoch: UInt64

    public init?(page: UnsafeMutablePointer<UInt8>, token: UInt32, epoch: UInt64) {
        guard token != 0,
              epoch != 0,
              Self.snapshot(page: page, token: token, epoch: epoch) != nil
        else {
            return nil
        }
        self.page = page
        self.expectedToken = token
        self.expectedEpoch = epoch
    }

    public static func initialize(page: UnsafeMutablePointer<UInt8>, token: UInt32) -> Bool {
        guard let header = ReixTextSurfaceRingHeader.proposal(token: token) else {
            return false
        }
        for index in 0..<ReixTextSurfaceTransport.pageBytes {
            page[index] = 0
        }
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
        else {
            return false
        }
        return accepted.encode(into: page, capacity: ReixTextSurfaceTransport.headerBytes)
    }

    public func push(_ command: ReixTextSurfaceCommand) -> Bool {
        guard let header = header() else {
            return false
        }
        let distance = header.producer &- header.consumer
        guard distance < UInt32(header.capacity) else {
            return false
        }
        dmbISH()
        let slot = Int(header.producer % UInt32(header.capacity))
        let address = page.advanced(by: ReixTextSurfaceTransport.headerBytes + slot * Int(header.recordBytes))
        guard command.encode(into: address, capacity: Int(header.recordBytes)) else {
            return false
        }
        dmbISH()
        Self.storeCursor(page, offset: Self.producerOffset, value: header.producer &+ 1)
        return true
    }

    public func pop(sequence: UInt32) -> ReixTextSurfaceCommand? {
        guard let header = header(),
              header.producer != header.consumer,
              sequence != 0
        else {
            return nil
        }
        dmbISH()
        let slot = Int(header.consumer % UInt32(header.capacity))
        let address = page.advanced(by: ReixTextSurfaceTransport.headerBytes + slot * Int(header.recordBytes))
        guard let command = ReixTextSurfaceCommand.decode(UnsafePointer(address), length: Int(header.recordBytes)),
              command.sequence == sequence
        else {
            return nil
        }
        dmbISH()
        Self.storeCursor(page, offset: Self.consumerOffset, value: header.consumer &+ 1)
        return command
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
              header.epoch != 0,
              header.producer &- header.consumer <= UInt32(header.capacity)
        else {
            return nil
        }
        return header
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
