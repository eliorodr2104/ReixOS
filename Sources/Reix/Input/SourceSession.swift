//
//  SourceSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// The producer-owned InputServer page used by one hardware adapter.
public final class SourceSession {
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64

    public init?(endpoint: UInt32, callback: UInt32) {
        let shared = shmCreate(pageCount: 1)
        guard shared.isValid,
              shared.handle != 0,
              callback != 0,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let token = shared.handle
        let epoch: UInt64 = 1
        func release() {
            _ = munmap(addr: shared.address, size: UInt64(ReixInputRing.pageBytes))
            _ = capDrop(shared.handle)
        }
        guard ReixInputRing.initialize(page: page, token: token, epoch: epoch) else { release(); return nil }
        var registration = InlineArray<4, UInt32>(repeating: 0)
        registration[0] = token
        registration[1] = UInt32(epoch)
        guard send(
            handle: endpoint,
            message: Message(
                tag: MessageTag(ReixInputServerOperation.registerSourceRing, length: 2),
                words: registration
            ),
            grant: shared.handle,
            grantRights: [.send, .read, .write]
        ).isDelivered else { release(); return nil }
        guard send(
            handle: endpoint,
            message: Message(
                tag: MessageTag(ReixInputServerOperation.registerSourceCallback, length: 0),
                words: InlineArray<4, UInt32>(repeating: 0)
            ),
            grant: callback,
            grantRights: [.send]
        ).isDelivered else { release(); return nil }
        guard case .success(let reply) = call(
            handle: endpoint,
            message: Message(
                tag: MessageTag(ReixInputServerOperation.status, length: 0),
                words: InlineArray<4, UInt32>(repeating: 0)
            )
        ), reply.message.words[0] == ReixInputServerStatus.ok.rawValue
        else { release(); return nil }
        self.handle = shared.handle
        self.address = shared.address
        self.token = token
        self.epoch = epoch
    }

    deinit {
        _ = munmap(addr: address, size: UInt64(ReixInputRing.pageBytes))
        _ = capDrop(handle)
    }

    public func publish(_ record: ReixInputRecord) -> ReixInputServerStatus {
        guard let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixInputRing(page: page, token: token, epoch: epoch)
        else { return .stale }
        return ring.push(record)
    }
}
