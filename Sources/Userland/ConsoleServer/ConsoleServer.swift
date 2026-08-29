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

    private let endpoint    : UInt32
    private var serialWriter: SerialWriterSession
    private var clients     : InlineArray<32, UInt32?> = InlineArray(repeating: nil)
    private var rings       : InlineArray<32, Ring?>   = InlineArray(repeating: nil)

    private var grantedCaps: InlineArray<32, UInt32?> = InlineArray(repeating: nil)
    private var indexClient: Int = 0

    public var serviceEndpoint: UInt32 { endpoint }

    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.endpoint = endpoint

        guard let serial = environment.serialWriter,
              let writer = SerialWriterSession(endpoint: serial)
        else { exit(code: 1) }

        self.serialWriter = writer

        print("[ SERVE ] Console Server running")
    }

    public mutating func handle(
        _ operation: ConsoleOperation,
          request  : inout ReceivedMessage
    ) {

        switch operation {
            case .register:
                register(&request)

            case .drainPartial:
                if let slot = slot(for: request.identity), let ring = rings[slot] {
                    drain(ring, includingPartialLine: true)
                }

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
                    let flushed = serialWriter.flush()
                    status = ConsoleStatus.afterSerialFlush(hasRing: true, flush: flushed)
                }

                _ = reply(message: ConsoleOperation.flush.message(word0: status.rawValue))
        }
    }

    /// Adopt the caller's ring buffer, or refuse and let the grant go back.
    ///
    /// The grant is only *inspected* until the ring is mapped and a slot is
    /// committed to it, so every refusal can simply return: `run()` releases what
    /// was never taken. `takeGrant()` marks the single point of no return: past
    /// it the capability belongs to `grantedCaps` and `release(slot:)` owns it.
    private mutating func register(_ request: inout ReceivedMessage) {

        let badge = request.identity

        guard badge != 0 else {
            print("[ SERVE ] Console register refused: no caller identity")
            return
        }

        guard let grantedCap = request.grantedCap else {
            // The one refusal with nothing to give back: there was no grant.
            print("[ SERVE ] Console register refused: no ring granted")
            return
        }

        guard request.message.words[0] == Self.ringPages else {
            print("[ SERVE ] Console register refused: ring is not one page")
            return
        }

        if let stale = slot(for: badge) { release(slot: stale) }

        // Before refusing, ask which of the thirty-two are still there: a client
        // that died used to hold its slot, and its page, for the whole boot.
        if freeSlot() == nil { sweepDeadClients() }

        guard let slot = freeSlot() else {
            print("[ SERVE ] Console register refused: no free slot")
            return
        }

        let mapped = shmMap(handle: grantedCap)
        guard let ringBase = UnsafeMutableRawPointer(bitPattern: UInt(mapped)) else {
            print("[ SERVE ] Console register refused: cannot map the ring")
            return
        }

        clients[slot]     = badge
        rings[slot]       = Ring(base: ringBase, regionSize: Self.pageSize)
        grantedCaps[slot] = request.takeGrant()
    }

    /// Moves complete lines without freeing bytes the serial writer rejected.
    /// Partial lines drain only on request or when the producer fills the ring.
    private mutating func drain(
        _                    ring   : Ring,
        includingPartialLine partial: Bool = false
    ) {

        @inline(__always)
        func stageLine(
            _ first      : UnsafeRawPointer,
            _ firstCount : Int,
            _ second     : UnsafeRawPointer?,
            _ secondCount: Int
        ) -> Bool {
            serialWriter.stage(
                first      : first.assumingMemoryBound(to: UInt8.self),
                firstCount : firstCount,
                second     : second?.assumingMemoryBound(to: UInt8.self),
                secondCount: secondCount
            ) == .ok
        }

        while ring.consumeLineChecked(stageLine) { }

        if partial || ring.isFull {
            _ = ring.consumeAllChecked(stageLine)
        }
        _ = serialWriter.flush()
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

    /// Lets go of every slot whose client is no longer running.
    ///
    /// What is drained before it goes is deliberate: a dead writer's last lines
    /// were written into a ring this process can still read, and throwing them
    /// away would lose exactly the output of whatever killed it.
    private mutating func sweepDeadClients() {
        for index in 0..<clients.count {
            guard let badge = clients[index], !identityAlive(badge) else { continue }

            if let ring = rings[index] { drain(ring, includingPartialLine: true) }

            release(slot: index)
        }
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
