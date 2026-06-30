//
//  ConsoleClient.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

public struct ConsoleClient {

    private static let pageSize = 4096

    private let endpoint: UInt32
    private let client  : UInt32
    private let ring    : Ring

    public init?(console endpoint: UInt32) {
        let shm = shmCreate(pageCount: 1)
        guard shm.isValid else { return nil }

        self.endpoint = endpoint
        self.client   = UInt32(truncatingIfNeeded: getPID())
        self.ring     = Ring(
            base      : UnsafeMutableRawPointer(bitPattern: UInt(shm.address))!,
            regionSize: Self.pageSize
        )
        self.ring.reset()

        _ = send(
            handle     : endpoint,
            message    : ConsoleOperation.register.message(client: client),
            grant      : shm.handle,
            grantRights: [.send]
        )
    }

    public func write(_ byte: UInt8) {
        _ = ring.push(byte)

        if byte == UInt8(ascii: "\n") {
            _ = send(handle: endpoint, message: ConsoleOperation.kick.message(client: client))
        }
    }
}


public enum Console {

    nonisolated(unsafe) static var client: ConsoleClient? = nil

    public static func attach(console endpoint: UInt32) {
        client = ConsoleClient(console: endpoint)
    }
}


@_cdecl("putchar")
public func putchar(ch: UInt8) {
    if let client = Console.client {
        client.write(ch)

    } else {
        _ = _syscall(.putchar, UInt64(ch))
    }
}
