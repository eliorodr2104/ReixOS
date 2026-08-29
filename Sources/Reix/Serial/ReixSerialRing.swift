//
//  ReixSerialRing.swift
//  ReixOS
//

import ReixABI

public enum ReixSerialRingPop {
    case chunk(ReixSerialChunk)
    case status(ReixSerialStatus)
}

/// One page, single producer and single consumer serial ring.
public struct ReixSerialRing {
    private static let producerOffset = 28
    private static let consumerOffset = 32

    private let page: UnsafeMutablePointer<UInt8>
    private let role: ReixSerialRingRole
    private let token: UInt32
    private let epoch: UInt64

    public init?(
        page: UnsafeMutablePointer<UInt8>,
        role: ReixSerialRingRole,
        token: UInt32,
        epoch: UInt64
    ) {
        guard epoch != 0, Self.valid(page: page, role: role, token: token, epoch: epoch) else { return nil }
        self.page = page
        self.role = role
        self.token = token
        self.epoch = epoch
    }

    public static func initialize(
        page: UnsafeMutablePointer<UInt8>,
        role: ReixSerialRingRole,
        token: UInt32,
        epoch: UInt64 = 0
    ) -> Bool {
        guard epoch == 0, let header = ReixSerialRingHeader.proposal(role: role, token: token) else { return false }
        for index in 0..<ReixSerialRingTransport.pageBytes { page[index] = 0 }
        return header.encode(into: page, capacity: ReixSerialRingTransport.headerBytes)
    }

    public static func accept(
        page: UnsafeMutablePointer<UInt8>,
        role: ReixSerialRingRole,
        token: UInt32,
        epoch: UInt64
    ) -> Bool {
        guard epoch != 0,
              let proposal = ReixSerialRingHeader.decode(
                UnsafePointer(page),
                length: ReixSerialRingTransport.headerBytes
              ),
              proposal.role == role,
              proposal.token == token,
              proposal.state == .proposed,
              let accepted = proposal.accepted(epoch: epoch)
        else { return false }
        return accepted.encode(into: page, capacity: ReixSerialRingTransport.headerBytes)
    }

    public func accept() -> ReixSerialStatus {
        Self.valid(page: page, role: role, token: token, epoch: epoch) ? .ok : .stale
    }

    public func push(_ chunk: ReixSerialChunk) -> ReixSerialStatus {
        guard Self.valid(page: page, role: role, token: token, epoch: epoch) else { return .stale }
        guard (role == .reader && chunk.direction == .receive)
                || (role == .writer && chunk.direction == .transmit)
        else { return .malformed }
        let producer = Self.cursor(page, Self.producerOffset)
        let consumer = Self.cursor(page, Self.consumerOffset)
        guard producer &- consumer < UInt32(ReixSerialRingTransport.capacity) else { return .full }
        dmbISH()
        let slot = Int(producer % UInt32(ReixSerialRingTransport.capacity))
        let destination = page.advanced(by: ReixSerialRingTransport.headerBytes + slot * ReixSerialProtocol.recordBytes)
        guard chunk.encode(into: destination, capacity: ReixSerialProtocol.recordBytes) else { return .malformed }
        dmbISH()
        Self.store(page, Self.producerOffset, producer &+ 1)
        return .ok
    }

    public func pop() -> ReixSerialRingPop {
        guard Self.valid(page: page, role: role, token: token, epoch: epoch) else { return .status(.stale) }
        let producer = Self.cursor(page, Self.producerOffset)
        let consumer = Self.cursor(page, Self.consumerOffset)
        guard producer != consumer else { return .status(.empty) }
        dmbISH()
        let slot = Int(consumer % UInt32(ReixSerialRingTransport.capacity))
        let source = page.advanced(by: ReixSerialRingTransport.headerBytes + slot * ReixSerialProtocol.recordBytes)
        guard let chunk = ReixSerialChunk.decode(UnsafePointer(source), length: ReixSerialProtocol.recordBytes),
              (role == .reader && chunk.direction == .receive) || (role == .writer && chunk.direction == .transmit)
        else { return .status(.malformed) }
        dmbISH()
        Self.store(page, Self.consumerOffset, consumer &+ 1)
        return .chunk(chunk)
    }

    public var isFull: Bool {
        guard Self.valid(page: page, role: role, token: token, epoch: epoch) else { return true }
        return Self.cursor(page, Self.producerOffset)
            &- Self.cursor(page, Self.consumerOffset)
            >= UInt32(ReixSerialRingTransport.capacity)
    }

    public var isEmpty: Bool {
        guard Self.valid(page: page, role: role, token: token, epoch: epoch) else { return false }
        return Self.cursor(page, Self.producerOffset) == Self.cursor(page, Self.consumerOffset)
    }

    public var freeSlots: Int? {
        guard Self.valid(page: page, role: role, token: token, epoch: epoch) else { return nil }
        let used = Self.cursor(page, Self.producerOffset) &- Self.cursor(page, Self.consumerOffset)
        return ReixSerialRingTransport.capacity - Int(used)
    }

    private static func valid(
        page: UnsafeMutablePointer<UInt8>,
        role: ReixSerialRingRole,
        token: UInt32,
        epoch: UInt64
    ) -> Bool {
        guard let header = ReixSerialRingHeader.decode(
            UnsafePointer(page),
            length: ReixSerialRingTransport.headerBytes
        ) else { return false }
        return header.role == role
            && header.token == token
            && header.epoch == epoch
            && header.producer &- header.consumer <= UInt32(ReixSerialRingTransport.capacity)
    }

    private static func cursor(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int) -> UInt32 {
        UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self).pointee
    }

    private static func store(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt32) {
        UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self).pointee = value
    }
}
