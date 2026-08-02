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

    private static let ringPages: UInt32 = 1

    private let endpoint   : UInt32
    private let uartBase   : UnsafeMutableRawPointer
    private var clients    : InlineArray<32, UInt32?> = InlineArray(repeating: nil)
    private var rings      : InlineArray<32, Ring?>   = InlineArray(repeating: nil)
    
    private var grantedCaps: InlineArray<32, UInt32?> = InlineArray(repeating: nil)
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
                register(request)

            case .kick:
                for offset in 0..<clients.count {
                    let slot = (indexClient + offset) % clients.count
                    guard let ring = rings[slot] else { continue }
                    drain(ring)
                }
                indexClient = (indexClient + 1) % clients.count

            case .flush:
                var status = ConsoleStatus.unregistered

                if let slot = slot(for: request.identity), let ring = rings[slot] {
                    drain(ring)
                    status = .registered
                }

                _ = reply(message: ConsoleOperation.flush.message(word0: status.rawValue))
        }
    }

    private mutating func register(_ request: ReceivedMessage) {

        let badge = request.identity

        guard badge != 0 else {
            print("[ SERVE ] Console register refused: no caller identity")
            if let grantedCap = request.grantedCap { _ = capDrop(grantedCap) }
            return
        }

        guard let grantedCap = request.grantedCap else {
            // The one refusal with nothing to give back: there was no grant.
            print("[ SERVE ] Console register refused: no ring granted")
            return
        }

        guard request.message.words[0] == Self.ringPages else {
            print("[ SERVE ] Console register refused: ring is not one page")
            _ = capDrop(grantedCap)
            return
        }

        if let stale = slot(for: badge) { release(slot: stale) }

        guard let slot = freeSlot() else {
            print("[ SERVE ] Console register refused: no free slot")
            _ = capDrop(grantedCap)
            return
        }

        let mapped = shmMap(handle: grantedCap)
        guard let ringBase = UnsafeMutableRawPointer(bitPattern: UInt(mapped)) else {
            print("[ SERVE ] Console register refused: cannot map the ring")
            _ = capDrop(grantedCap)
            return
        }

        clients[slot]     = badge
        rings[slot]       = Ring(base: ringBase, regionSize: Self.pageSize)
        grantedCaps[slot] = grantedCap
    }

    private func drain(_ ring: Ring) {
        let flagRegister = uartBase + 0x18

        func writeSpan(
            _ bytes: UnsafeRawPointer,
              count: Int
        ) {
            for offset in 0..<count {
                let byte = bytes.load(fromByteOffset: offset, as: UInt8.self)

                while (flagRegister.load(as: UInt32.self) & 0x20) != 0 { }
                uartBase.storeBytes(of: byte, as: UInt8.self)
            }
        }

        while ring.consumeLine(writeSpan) { }

        guard ring.isFull else { return }
        ring.consumeAll(writeSpan)
    }

    private mutating func release(slot: Int) {

        if let ring = rings[slot] {
            _ = munmap(
                addr: UInt64(UInt(bitPattern: ring.regionBase)),
                size: UInt64(Self.pageSize)
            )
        }

        if let grantedCap = grantedCaps[slot] { _ = capDrop(grantedCap) }

        clients[slot]     = nil
        rings[slot]       = nil
        grantedCaps[slot] = nil
    }

    /// Slot held by the client with this badge, if any.
    ///
    /// Badge `0` is "no identity" and never matches: identities start at 1, so
    /// zero names no live process and no slot is ever keyed on it.
    private func slot(for badge: UInt32) -> Int? {
        guard badge != 0 else { return nil }

        for i in 0..<clients.count where clients[i] == badge { return i }
        return nil
    }

    private func freeSlot() -> Int? {
        for i in 0..<clients.count where clients[i] == nil { return i }
        return nil
    }
}
