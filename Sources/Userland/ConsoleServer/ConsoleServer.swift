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

    private let endpoint   : UInt32
    private let uartBase   : UnsafeMutableRawPointer
    private var clients    : InlineArray<32, UInt32?> = InlineArray(repeating: nil)
    private var rings      : InlineArray<32, Ring?>   = InlineArray(repeating: nil)
    private var indexClient: Int = 0

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

        guard let uartBase = UnsafeMutableRawPointer(
            bitPattern: UInt(mapDevice(handle: deviceCap))
        
        ) else {
            print("[ SERVE ] Console Server cannot map the UART")
            exit(code: 1)
        }

        self.uartBase = uartBase

        print("[ SERVE ] Console Server running")
    }

    public mutating func handle(
        _ operation: ConsoleOperation,
          request  : ReceivedMessage
    ) {
        switch operation {
            case .register:
                let client = request.message.words[0]
                guard let slot       = slot(for: client) ?? freeSlot(),
                      let grantedCap = request.grantedCap
                else { return }

                let mapped = shmMap(handle: grantedCap)
                guard let ringBase = UnsafeMutableRawPointer(bitPattern: UInt(mapped)) else { return }

                clients[slot] = client
                rings[slot]   = Ring(base: ringBase, regionSize: Self.pageSize)

            case .kick:
                for offset in 0..<clients.count {
                    let slot = (indexClient + offset) % clients.count
                    guard let ring = rings[slot] else { continue }
                    drain(ring)
                }
                indexClient = (indexClient + 1) % clients.count

            case .flush:
                let client = request.message.words[0]
                if let slot = slot(for: client), let ring = rings[slot] {
                    drain(ring)
                }
                _ = reply(message: ConsoleOperation.flush.message(client: 0))
        }
    }
    
    private func drain(_ ring: Ring) {
        let flagRegister = uartBase + 0x18

        func writeByte(_ byte: UInt8) {
            while (flagRegister.load(as: UInt32.self) & 0x20) != 0 { }
            uartBase.storeBytes(of: byte, as: UInt8.self)
        }

        while let length = ring.nextLineLength() {
            for _ in 0..<length {
                if let byte = ring.pop() { writeByte(byte) }
            }
        }

        guard ring.isFull else { return }
        while let byte = ring.pop() { writeByte(byte) }
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
