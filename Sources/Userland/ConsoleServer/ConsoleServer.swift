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

        self.uartBase = UnsafeMutableRawPointer(
            bitPattern: UInt(mapDevice(handle: deviceCap))
        )!

        print("[ SERVE ] Console Server running")
    }

    public mutating func handle(
        _ operation: ConsoleOperation,
          request  : ReceivedMessage
    ) {
        switch operation {
            case .register:
                let client = request.message.words[0]
                guard let slot = slot(for: client) ?? freeSlot() else { return }

                clients[slot] = client
                rings[slot]   = Ring(
                    base      : UnsafeMutableRawPointer(bitPattern: UInt(shmMap(handle: request.grantedCap!)))!,
                    regionSize: Self.pageSize
                )

            case .kick:
                let flagRegister = uartBase + 0x18

                for offset in 0..<clients.count {
                    let slot = (indexClient + offset) % clients.count
                    guard let ring = rings[slot] else { continue }

                    while let length = ring.nextLineLength() {
                        
                        for _ in 0..<length {
                            if let byte = ring.pop() {
                                
                                while (flagRegister.load(as: UInt32.self) & 0x20) != 0 { }
                                uartBase.storeBytes(of: byte, as: UInt8.self)
                                
                            }
                        }
                    }
                }
                
                indexClient = (indexClient + 1) % clients.count
                
                
            case .flush:
                let flagRegister = uartBase + 0x18
                let client       = request.message.words[0]
                
                if let slot = slot(for: client), let ring = rings[slot] {
                    
                    while let length = ring.nextLineLength() {
                        
                        for _ in 0..<length {
                            if let byte = ring.pop() {
                                
                                while (flagRegister.load(as: UInt32.self) & 0x20) != 0 { }
                                uartBase.storeBytes(of: byte, as: UInt8.self)
                                
                            }
                        }
                    }
                    
                }
                
                _ = reply(message: ConsoleOperation.flush.message(client: 0))
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
