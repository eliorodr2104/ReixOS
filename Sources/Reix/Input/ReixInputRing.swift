//
//  ReixInputRing.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

public enum ReixInputRingPop {
    case record(ReixInputRecord)
    case status(ReixInputServerStatus)
}

/// One page SPSC record ring used independently for source and consumer.
///
/// **Producer** whoever holds the writing end, through `push`.
/// **Consumer** whoever holds the reading end, through `pop`.
/// **Publication** the record is encoded into its slot, then a release barrier,
/// then the producer cursor moves by one. The consumer reads both cursors into
/// locals, takes an acquire barrier, decodes the slot and only then moves the
/// consumer cursor.
/// **Incomplete record** there is none to detect: a slot is published by the
/// cursor move and never before, so a half-written record is never visible. A
/// record that decodes to nothing is `.malformed` and the cursor does not move,
/// which is a ring that has stopped rather than one that skips.
/// **Peer death** the magic, version, record width, capacity, epoch and token
/// are checked on every operation, so a page reused by a new session reads as
/// `.stale`. A peer that simply stops leaves the ring `.empty` or `.full`.
///
/// **Bounds** the page is one page and the capacity is fixed, so every slot
/// address is `header + (cursor % capacity) * recordBytes` and cannot leave it
/// whatever the cursors hold. `valid` additionally refuses a pair of cursors
/// whose difference exceeds the capacity, which is what a wrapped or forged
/// counter looks like from here.
public struct ReixInputRing {
    public static let pageBytes = 4096
    public static let headerBytes = 64
    public static let capacity = 126

    private static let producerOffset = 28
    private static let consumerOffset = 32
    private let page: UnsafeMutablePointer<UInt8>
    private let token: UInt32
    private let epoch: UInt64

    public init?(page: UnsafeMutablePointer<UInt8>, token: UInt32, epoch: UInt64) {
        guard token != 0, epoch != 0,
              Self.valid(page: page, token: token, epoch: epoch)
        else { return nil }
        self.page = page
        self.token = token
        self.epoch = epoch
    }

    public static func initialize(page: UnsafeMutablePointer<UInt8>, token: UInt32, epoch: UInt64) -> Bool {
        guard token != 0, epoch != 0 else { return false }
        for index in 0..<pageBytes { page[index] = 0 }
        inputWrite32(page, 0, 0x504E_4952)
        inputWrite16(page, 4, ReixInputProtocol.version)
        inputWrite16(page, 6, UInt16(ReixInputProtocol.recordBytes))
        inputWrite16(page, 8, UInt16(capacity))
        write64(page, 16, epoch)
        inputWrite32(page, 24, token)
        return true
    }

    public func push(_ record: ReixInputRecord) -> ReixInputServerStatus {
        guard Self.valid(page: page, token: token, epoch: epoch) else { return .stale }
        let producer = Self.cursor(page, Self.producerOffset)
        let consumer = Self.cursor(page, Self.consumerOffset)
        guard producer &- consumer < UInt32(Self.capacity) else { return .full }
        dmbISH()
        let slot = Int(producer % UInt32(Self.capacity))
        let destination = page.advanced(by: Self.headerBytes + slot * ReixInputProtocol.recordBytes)
        guard record.encode(into: destination, capacity: ReixInputProtocol.recordBytes) else { return .malformed }
        dmbISH()
        Self.store(page, Self.producerOffset, producer &+ 1)
        return .ok
    }

    public var isFull: Bool {
        guard Self.valid(page: page, token: token, epoch: epoch) else { return true }
        return Self.cursor(page, Self.producerOffset) &- Self.cursor(page, Self.consumerOffset) >= UInt32(Self.capacity)
    }

    public func pop() -> ReixInputRingPop {
        guard Self.valid(page: page, token: token, epoch: epoch) else { return .status(.stale) }
        let producer = Self.cursor(page, Self.producerOffset)
        let consumer = Self.cursor(page, Self.consumerOffset)
        guard producer != consumer else { return .status(.empty) }
        dmbISH()
        let slot = Int(consumer % UInt32(Self.capacity))
        let source = page.advanced(by: Self.headerBytes + slot * ReixInputProtocol.recordBytes)
        guard let record = ReixInputRecord.decode(
            UnsafePointer(source),
            length: ReixInputProtocol.recordBytes
        ) else { return .status(.malformed) }
        dmbISH()
        Self.store(page, Self.consumerOffset, consumer &+ 1)
        return .record(record)
    }

    private static func valid(page: UnsafeMutablePointer<UInt8>, token: UInt32, epoch: UInt64) -> Bool {
        inputRead32(page, 0) == 0x504E_4952
            && inputRead16(page, 4) == ReixInputProtocol.version
            && inputRead16(page, 6) == UInt16(ReixInputProtocol.recordBytes)
            && inputRead16(page, 8) == UInt16(capacity)
            && read64(page, 16) == epoch
            && inputRead32(page, 24) == token
            && Self.cursor(page, Self.producerOffset) &- Self.cursor(page, Self.consumerOffset) <= UInt32(capacity)
    }

    private static func cursor(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int) -> UInt32 {
        UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self).pointee
    }

    private static func store(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt32) {
        UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self).pointee = value
    }
}

private func read64(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
    UInt64(inputRead32(bytes, offset)) | UInt64(inputRead32(bytes, offset + 4)) << 32
}

private func write64(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt64) {
    inputWrite32(bytes, offset, UInt32(truncatingIfNeeded: value))
    inputWrite32(bytes, offset + 4, UInt32(truncatingIfNeeded: value >> 32))
}

private func inputRead16(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func inputRead32(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

private func inputWrite16(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func inputWrite32(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt32) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
