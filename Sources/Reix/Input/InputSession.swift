//
//  InputSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// The consumer-owned InputServer page. It never sees a serial byte.
public struct InputSession: ~Copyable {
    private let endpoint: UInt32
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64

    public init?(endpoint: UInt32) {
        let shared = shmCreate(pageCount: 1)
        guard shared.isValid,
              shared.handle != 0,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let token = shared.handle
        let epoch: UInt64 = 1
        guard ReixInputRing.initialize(page: page, token: token, epoch: epoch) else {
            _ = munmap(addr: shared.address, size: UInt64(ReixInputRing.pageBytes))
            _ = capDrop(shared.handle)
            return nil
        }
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = token
        words[1] = UInt32(epoch)
        let status = send(
            handle: endpoint,
            message: Message(tag: MessageTag(ReixInputServerOperation.registerConsumer, length: 2), words: words),
            grant: shared.handle,
            grantRights: [.send, .read, .write]
        )
        guard status.isDelivered else {
            _ = munmap(addr: shared.address, size: UInt64(ReixInputRing.pageBytes))
            _ = capDrop(shared.handle)
            return nil
        }
        guard case .success(let reply) = call(
            handle: endpoint,
            message: Message(
                tag: MessageTag(ReixInputServerOperation.status, length: 0),
                words: InlineArray<4, UInt32>(repeating: 0)
            )
        ), reply.message.words[0] == ReixInputServerStatus.ok.rawValue else {
            _ = munmap(addr: shared.address, size: UInt64(ReixInputRing.pageBytes))
            _ = capDrop(shared.handle)
            return nil
        }
        self.endpoint = endpoint
        self.handle = shared.handle
        self.address = shared.address
        self.token = token
        self.epoch = epoch
    }

    deinit {
        _ = munmap(addr: address, size: UInt64(ReixInputRing.pageBytes))
        _ = capDrop(handle)
    }

    public mutating func next() -> ReixInputRecord? {
        while true {
            guard case .success(let reply) = call(
                handle: endpoint,
                message: Message(
                    tag: MessageTag(ReixInputServerOperation.pull, length: 0),
                    words: InlineArray<4, UInt32>(repeating: 0)
                )
            ), let status = ReixInputServerStatus(rawValue: reply.message.words[0])
            else {
                return nil
            }
            switch status {
                case .ok:
                    guard let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?
                        .assumingMemoryBound(to: UInt8.self),
                          let ring = ReixInputRing(page: page, token: token, epoch: epoch),
                          case .record(let record) = ring.pop()
                    else {
                        return nil
                    }
                    return record
                case .empty, .pending, .timedOut:
                    continue
                case .refused, .full, .malformed, .stale:
                    return nil
            }
        }
    }
}
