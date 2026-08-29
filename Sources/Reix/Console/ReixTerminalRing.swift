//
//  ReixTerminalRing.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// One fixed SPSC terminal page. The producer alone writes `producer`; the
/// consumer alone writes `consumer`. Both cursors are naturally aligned UInt32
/// words: a bytewise cursor store could be observed torn by the other process.
public struct ReixTerminalRing {
    private static let producerOffset = 28
    private static let consumerOffset = 32

    private let page: UnsafeMutablePointer<UInt8>
    private let role: ReixTerminalRingRole
    private let expectedToken: UInt32
    private let expectedEpoch: UInt64

    public init?(page: UnsafeMutablePointer<UInt8>, role: ReixTerminalRingRole, token: UInt32, epoch: UInt64) {
        guard token != 0, epoch != 0,
              Self.snapshot(page: page, role: role, token: token, epoch: epoch) != nil
        else { return nil }
        self.page = page
        self.role = role
        self.expectedToken = token
        self.expectedEpoch = epoch
    }

    public static func initialize(page: UnsafeMutablePointer<UInt8>, role: ReixTerminalRingRole, token: UInt32) -> Bool {
        guard let header = ReixTerminalRingHeader.proposal(role: role, token: token) else { return false }
        for index in 0..<ReixTerminalTransport.pageBytes { page[index] = 0 }
        return header.encode(into: page, capacity: ReixTerminalTransport.headerBytes)
    }

    public static func accept(page: UnsafeMutablePointer<UInt8>, role: ReixTerminalRingRole, token: UInt32, epoch: UInt64) -> Bool {
        let producer = loadCursor(page, offset: producerOffset)
        let consumer = loadCursor(page, offset: consumerOffset)
        guard let proposal = ReixTerminalRingHeader.decode(UnsafePointer(page), length: ReixTerminalTransport.headerBytes, producer: producer, consumer: consumer),
              proposal.role == role,
              proposal.token == token,
              proposal.state == .proposed,
              proposal.producer == 0,
              proposal.consumer == 0,
              let accepted = proposal.accepted(epoch: epoch)
        else { return false }
        return accepted.encode(into: page, capacity: ReixTerminalTransport.headerBytes)
    }

    public func push(_ record: ReixInputRecord) -> Bool {
        guard role == .input, let header = header() else { return false }
        return push(record, header: header) { $0.encode(into: $1, capacity: $2) }
    }

    public func push(_ command: ReixTextSurfaceCommand) -> Bool {
        guard role == .surface, let header = header() else { return false }
        return push(command, header: header) { $0.encode(into: $1, capacity: $2) }
    }

    public func popInput(sequence: UInt32) -> ReixInputRecord? {
        guard role == .input else { return nil }
        return pop(sequence: sequence, decode: { ReixInputRecord.decode($0, length: $1) }, matches: { $0.sequence == sequence })
    }

    public func popSurface(sequence: UInt32) -> ReixTextSurfaceCommand? {
        guard role == .surface else { return nil }
        return pop(sequence: sequence, decode: { ReixTextSurfaceCommand.decode($0, length: $1) }, matches: { $0.sequence == sequence })
    }

    private func push<T>(_ value: T, header: ReixTerminalRingHeader, _ encode: (T, UnsafeMutablePointer<UInt8>, Int) -> Bool) -> Bool {
        let distance = header.producer &- header.consumer
        guard distance < UInt32(header.capacity) else { return false }
        // Acquire the peer's consumer update before reusing this slot.
        dmbISH()
        let slot = Int(header.producer % UInt32(header.capacity))
        let address = page.advanced(by: ReixTerminalTransport.headerBytes + slot * Int(header.recordBytes))
        for index in 0..<Int(header.recordBytes) { address[index] = 0 }
        guard encode(value, address, Int(header.recordBytes)) else { return false }
        // Release the complete slot before publishing producer.
        dmbISH()
        Self.storeCursor(page, offset: Self.producerOffset, value: header.producer &+ 1)
        return true
    }

    private func pop<T>(sequence: UInt32, decode: (UnsafePointer<UInt8>, Int) -> T?, matches: (T) -> Bool) -> T? {
        guard let header = header(), header.producer != header.consumer else { return nil }
        // Acquire the producer's slot before decoding it.
        dmbISH()
        let slot = Int(header.consumer % UInt32(header.capacity))
        let address = page.advanced(by: ReixTerminalTransport.headerBytes + slot * Int(header.recordBytes))
        guard sequence != 0,
              let result = decode(UnsafePointer(address), Int(header.recordBytes)),
              matches(result)
        else { return nil }
        // Release completed consumption before publishing consumer.
        dmbISH()
        Self.storeCursor(page, offset: Self.consumerOffset, value: header.consumer &+ 1)
        return result
    }

    private func header() -> ReixTerminalRingHeader? {
        Self.snapshot(page: page, role: role, token: expectedToken, epoch: expectedEpoch)
    }

    private static func snapshot(page: UnsafeMutablePointer<UInt8>, role: ReixTerminalRingRole, token: UInt32, epoch: UInt64) -> ReixTerminalRingHeader? {
        let producer = loadCursor(page, offset: producerOffset)
        let consumer = loadCursor(page, offset: consumerOffset)
        guard let header = ReixTerminalRingHeader.decode(UnsafePointer(page), length: ReixTerminalTransport.headerBytes, producer: producer, consumer: consumer),
              header.role == role,
              header.recordBytes == ReixTerminalRingHeader.expectedRecordBytes(role),
              header.capacity == ReixTerminalRingHeader.expectedCapacity(role),
              header.features == ReixTerminalTransport.supportedFeatures,
              header.state == .accepted,
              header.token == token,
              header.epoch == epoch,
              header.epoch != 0,
              header.producer &- header.consumer <= UInt32(header.capacity)
        else { return nil }
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
