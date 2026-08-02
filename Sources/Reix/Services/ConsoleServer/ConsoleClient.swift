//
//  ConsoleClient.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

public struct ConsoleClient {

    /// The ring is exactly one page, and the server hard-codes that size:
    /// `shmMap` returns an address and no length, so the two sides can only agree
    /// on the region size by contract.
    private static let pageSize : Int    = 4096
    private static let ringPages: UInt32 = 1
    private static let newLine  : UInt8  = UInt8(ascii: "\n")

    /// How many times `write` asks the server to drain a full ring before giving
    /// up on the ring for that byte. Unbounded retries used to be a livelock: a
    /// registration the server dropped means nothing ever drains, and `push`
    /// never succeeds again.
    private static let flushAttempts = 4

    private let endpoint: UInt32
    private let ring    : Ring

    public init?(console endpoint: UInt32) {
       
        let shm = shmCreate(pageCount: UInt64(Self.ringPages))
        
        guard shm.isValid, let base = UnsafeMutableRawPointer(
            bitPattern: UInt(shm.address)
        ) else { return nil }
        

        self.endpoint = endpoint
        self.ring     = Ring(
            base      : base,
            regionSize: Self.pageSize
        )
        self.ring.reset()
        

        send(
            handle     : endpoint,
            message    : ConsoleOperation.register.message(word0: Self.ringPages),
            grant      : shm.handle,
            grantRights: [.send]
        )
        

        let response = call(
            handle : endpoint,
            message: ConsoleOperation.flush.message()
        )
        
        guard Self.isRegistered(response) else { return nil }
    }

    public func write(_ byte: UInt8) -> ConsoleWrite {

        if !ring.push(byte) {
            let result = drainAndRetry(byte)
            guard result == .accepted else { return result }
        }

        if byte == Self.newLine {
            send(
                handle : endpoint,
                message: ConsoleOperation.kick.message()
            )
        }

        return .accepted
    }

    /// Slow path for a full ring: ask the server to drain and retry, a bounded
    /// number of times.
    ///
    /// The reply doubles as a liveness check, which is what separates real
    /// backpressure from a registration the server dropped, in the latter case
    /// draining is a no-op and retrying would never terminate.
    private func drainAndRetry(_ byte: UInt8) -> ConsoleWrite {

        for _ in 0..<Self.flushAttempts {
            
            let response = call(
                handle : endpoint,
                message: ConsoleOperation.flush.message()
            )
            
            guard Self.isRegistered(response) else {
                return .unregistered
            }

            if ring.push(byte) { return .accepted }
        }

        return .backpressure
    }

    private static func isRegistered(_ response: ReceivedMessage) -> Bool {
        ConsoleStatus(rawValue: response.message.words[0]) == .registered
    }
}

@_cdecl("putchar")
public func putchar(ch: UInt8) {

    guard let client = Console.client else {
        _ = _syscall(.putchar, UInt64(ch))
        return
    }

    switch client.write(ch) {
        case .accepted: break

        case .backpressure:
            _syscall(.putchar, UInt64(ch))

        case .unregistered:
            Console.client = nil
            _syscall(.putchar, UInt64(ch))
    }
}
