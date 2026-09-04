//
//  SerialSessions.swift
//  ReixOS
//

import ReixABI

/// A client-owned receive page registered with SerialServer.
public final class SerialReaderSession {
    private let endpoint: UInt32
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64

    public init?(endpoint: UInt32) {
        guard let state = serialOpen(endpoint: endpoint, operation: .registerReader, role: .reader) else { return nil }
        self.endpoint = endpoint
        self.handle = state.handle
        self.address = state.address
        self.token = state.token
        self.epoch = state.epoch
    }

    deinit { serialClose(handle: handle, address: address) }

    public func read() -> ReixSerialRingPop {
        guard case .success(let reply) = call(
            handle: endpoint,
            message: serialMessage(.read, token: token, epoch: epoch)
        ),
              let status = ReixSerialStatus(rawValue: reply.message.words[0]),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixSerialRing(page: page, role: .reader, token: token, epoch: epoch)
        else { return .status(.stale) }
        guard status == .ok else { return .status(status) }
        return ring.pop()
    }
}

/// A client-owned transmit page registered with SerialServer.
public final class SerialWriterSession {
    /// One server call makes bounded progress through the writer ring. A ring
    /// contains at most this many chunks, so this bound can drain every byte
    /// already owned by the session without an unbounded retry loop.
    private static let maximumFlushAttempts = ReixSerialRingTransport.capacity + 1

    private let endpoint: UInt32
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64
    private var sequence: UInt32 = 1
    private var needsFlush = false

    public init?(endpoint: UInt32) {
        guard let state = serialOpen(endpoint: endpoint, operation: .registerWriter, role: .writer) else { return nil }
        self.endpoint = endpoint
        self.handle = state.handle
        self.address = state.address
        self.token = state.token
        self.epoch = state.epoch
    }

    deinit { serialClose(handle: handle, address: address) }

    public func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> ReixSerialStatus {
        stage(first: bytes, firstCount: count, second: nil, secondCount: 0)
    }

    /// Stages two adjacent spans as one logical serial stream.
    public func stage(
        first: UnsafePointer<UInt8>,
        firstCount: Int,
        second: UnsafePointer<UInt8>?,
        secondCount: Int
    ) -> ReixSerialStatus {
        guard firstCount >= 0, secondCount >= 0 else {
            return .malformed
        }
        guard let page = UnsafeMutableRawPointer(
            bitPattern: UInt(address)
        )?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixSerialRing(page: page, role: .writer, token: token, epoch: epoch)
        else { return .stale }
        let sum = firstCount.addingReportingOverflow(secondCount)
        guard !sum.overflow else { return .malformed }
        let count = sum.partialValue
        guard count > 0 else { return .ok }
        guard secondCount == 0 || second != nil else { return .malformed }
        var offset = 0
        while offset < count {
            guard var freeSlots = ring.freeSlots else { return .stale }
            if freeSlots == 0 {
                let flushed = flush()
                guard flushed == .ok else { return flushed }
                guard let available = ring.freeSlots, available > 0 else { return .full }
                freeSlots = available
            }
            let room = freeSlots * ReixSerialProtocol.maximumPayload
            let batchEnd = offset + min(count - offset, room)
            while offset < batchEnd {
                let amount = min(ReixSerialProtocol.maximumPayload, batchEnd - offset)
                var payload = InlineArray<48, UInt8>(repeating: 0)
                for index in 0..<amount {
                    let source = offset + index
                    if source < firstCount {
                        payload[index] = first[source]
                    } else if let second {
                        payload[index] = second[source - firstCount]
                    } else {
                        return .malformed
                    }
                }
                guard let chunk = ReixSerialChunk(
                    direction: .transmit,
                    sequence: sequence,
                    payload: payload,
                    count: amount
                ) else { return .malformed }
                let pushed = ring.push(chunk)
                guard pushed == .ok else { return pushed }
                sequence = sequence == UInt32.max ? 1 : sequence + 1
                offset += amount
            }
            needsFlush = true
            if offset < count {
                let flushed = flush()
                guard flushed == .ok else { return flushed }
            }
        }
        return .ok
    }

    public func flush() -> ReixSerialStatus {
        var attempts = 0
        while attempts < Self.maximumFlushAttempts {
            guard case .success(let reply) = call(
                handle: endpoint,
                message: serialMessage(.write, token: token, epoch: epoch)
            ),
                  let status = ReixSerialStatus(rawValue: reply.message.words[0])
            else { return .stale }
            if status == .ok {
                needsFlush = false
                return .ok
            }
            guard status == .pending else { return status }
            attempts += 1
        }
        return .pending
    }
}

private struct SerialSessionState {
    let handle: UInt32
    let address: UInt64
    let token: UInt32
    let epoch: UInt64
}

private func serialOpen(
    endpoint: UInt32,
    operation: ReixSerialServerOperation,
    role: ReixSerialRingRole
) -> SerialSessionState? {
    let shared = shmCreate(pageCount: 1)
    guard shared.isValid,
          shared.handle != 0,
          let page = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))?.assumingMemoryBound(to: UInt8.self)
    else { return nil }
    let token = shared.handle
    guard ReixSerialRing.initialize(page: page, role: role, token: token) else {
        serialClose(handle: shared.handle, address: shared.address)
        return nil
    }
    var words = InlineArray<4, UInt32>(repeating: 0)
    words[0] = token
    guard send(
        handle: endpoint,
        message: Message(tag: MessageTag(operation, length: 2), words: words),
        grant: shared.handle,
        grantRights: [.send, .read, .write]
    ).isDelivered,
          case .success(let reply) = call(handle: endpoint, message: serialMessage(.status, token: token)),
          reply.message.tag.length == 4,
          reply.message.words[0] == ReixSerialStatus.ok.rawValue,
          reply.message.words[1] == token
    else {
        serialClose(handle: shared.handle, address: shared.address)
        return nil
    }
    let epoch = UInt64(reply.message.words[2]) | UInt64(reply.message.words[3]) << 32
    guard epoch != 0, ReixSerialRing(page: page, role: role, token: token, epoch: epoch) != nil else {
        serialClose(handle: shared.handle, address: shared.address)
        return nil
    }
    return SerialSessionState(handle: shared.handle, address: shared.address, token: token, epoch: epoch)
}

private func serialClose(handle: UInt32, address: UInt64) {
    _ = munmap(addr: address, size: UInt64(ReixSerialRingTransport.pageBytes))
    _ = capDrop(handle)
}

private func serialMessage(_ operation: ReixSerialServerOperation, token: UInt32 = 0, epoch: UInt64 = 0) -> Message {
    var words = InlineArray<4, UInt32>(repeating: 0)
    words[0] = token
    words[1] = UInt32(truncatingIfNeeded: epoch)
    words[2] = UInt32(truncatingIfNeeded: epoch >> 32)
    return Message(tag: MessageTag(operation, length: token == 0 ? 0 : 3), words: words)
}
