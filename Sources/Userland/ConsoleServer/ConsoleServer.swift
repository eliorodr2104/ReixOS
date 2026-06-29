//
//  ConsoleServer.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import Reix

public struct ConsoleServer: Service {

    public static let manifest = ServiceManifest(provides: .parent)

    private static let pageSize = 4096

    private let endpoint: UInt32
    private let uartBase: UnsafeMutableRawPointer
    private var clients : InlineArray<32, UInt32?> = InlineArray(repeating: nil)
    private var rings   : InlineArray<32, Ring?>   = InlineArray(repeating: nil)

    public var serviceEndpoint: UInt32 { endpoint }

    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.endpoint = endpoint

        guard let deviceCap = environment.device else {
            print("[ SERVE ] Console Server has no device cap")
            exit(code: 1)
        }

        self.uartBase = UnsafeMutableRawPointer(
            bitPattern: UInt(mapDevice(handle: deviceCap))
        )!

        print("[ SERVE ] Console Server running")
    }

    public mutating func handle(
        _ operation: ConsoleOperation,
          request  : ReceivedMessage
    ) {
        let client = request.message.words[0]

        switch operation {
            case .register:
                guard let slot = slot(for: client) ?? freeSlot() else { return }

                clients[slot] = client
                rings[slot]   = Ring(
                    base      : UnsafeMutableRawPointer(bitPattern: UInt(shmMap(handle: request.grantedCap!)))!,
                    regionSize: Self.pageSize
                )

            case .kick:
                guard let slot = slot(for: client) else { return }

                let flagRegister = uartBase + 0x18

                while let byte = rings[slot]?.pop() {
                    while (flagRegister.load(as: UInt32.self) & 0x20) != 0 { }

                    uartBase.storeBytes(of: byte, as: UInt8.self)
                }
        }
    }

    private func slot(for client: UInt32) -> Int? {
        for i in 0..<clients.count where clients[i] == client { return i }
        return nil
    }

    private func freeSlot() -> Int? {
        for i in 0..<clients.count where clients[i] == nil { return i }
        return nil
    }
}
