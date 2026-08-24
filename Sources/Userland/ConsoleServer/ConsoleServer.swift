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
                    status = .registered
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

    /// Hand every complete line in `ring` to the UART, then the whole ring if it
    /// is full and holds no line at all.
    ///
    /// The byte loop and its FIFO-full wait live in `pl011WriteSpan`, in
    /// assembly. The same loop spelled in Swift lost its wait: `uartBase + 0x18`
    /// is not a volatile read, so LLVM hoisted the load out of the loop and then
    /// dropped it, and the shipped code stored into a FIFO it never checked.
    /// Writes out what a ring holds.
    ///
    /// Whole lines only, unless the caller asks otherwise or the ring is full.
    /// A ring that has filled without closing a line has to be emptied whatever
    /// it holds, or its writer is wedged behind bytes nobody will ever take.
    private func drain(
        _                    ring   : Ring,
        includingPartialLine partial: Bool = false
    ) {

        func writeSpan(
            _ bytes: UnsafeRawPointer,
              count: Int
        ) {
            pl011WriteSpan(uartBase, bytes, count)
        }

        while ring.consumeLine(writeSpan) { }

        guard partial || ring.isFull else { return }
        _ = ring.consumeAll(writeSpan)
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
