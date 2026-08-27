//
//  WideSessionTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// A session that uses the width the register has, through every path that
/// delivers one.
///
/// The session used to share a register with the sender's identity, thirty-two
/// bits each. Which meant a server's token could carry thirty-two bits and no
/// more, and the file system's own badge wanted more than that: an object number,
/// a generation, and eight bits of rights. What it did instead was give the
/// generation whatever was left, which on a sixteen megabyte disk was fourteen
/// bits - sixteen thousand removals of one slot before an old capability named a
/// new object.
///
/// So there are six paths that lay a session into a receiver's frame, and this is
/// the suite that says all six carry all sixty-four bits. They used to build the
/// word each for themselves.
@Suite("Wide sessions", .serialized)
struct WideSessionTests {

    /// Sessions that are wrong by exactly one bit if anything truncates.
    private static let wide: [Badge] = [
        1 << 32,
        1 << 63,
        0x0123_4567_89AB_CDEF,
        0xFFFF_FFFF_0000_0001,
        UInt64.max
    ]


    private func withPair(
        _ body: (
            UnsafeMutablePointer<KernelIPC>,
            UnsafeMutablePointer<Endpoint>,
            UnsafeMutablePointer<Process>,
            UnsafeMutablePointer<Process>
        ) -> Void
    ) {
        withProcessManager(pages: 160) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            guard let server = try? manager.pointee.spawnProcess(),
                  let client = try? manager.pointee.spawnProcess()
            else {
                Issue.record("could not spawn the pair")
                return
            }

            body(ipc, endpoint, server, client)
        }
    }


    private func give(
        _ ipc      : UnsafeMutablePointer<KernelIPC>,
        _ process  : UnsafeMutablePointer<Process>,
        on endpoint: UnsafeMutablePointer<Endpoint>,
        _ rights   : CapRights,
        session    : Badge = 0
    ) -> Capability {

        let capability = Capability(
            target: .endpoint(endpoint),
            badge : session,
            rights: rights
        )

        _ = process.pointee.metadata.pointee.capsTable.install(capability)
        ipc.pointee.retain(capability)

        return capability
    }


    private func frame(word: UInt32) -> Arch.TrapFrame {
        var trap = Arch.TrapFrame()
        trap.x1 = (UInt64(1) << 8) | 1   // one word, label one
        trap.x2 = UInt64(word)
        trap.x6 = UInt64(UInt32.max)     // no grant

        return trap
    }


    // MARK: - A receiver already waiting

    @Test("a send into a waiting receiver carries the whole session")
    func immediateSend() {
        for session in Self.wide {
            withPair { ipc, endpoint, server, client in
                let receive = give(ipc, server, on: endpoint, [.receive])
                let send    = give(ipc, client, on: endpoint, [.send], session: session)

                // The server parks first, so the send lands straight in its frame.
                var waiting = Arch.TrapFrame()
                withCurrentProcess(server) {
                    _ = withUnsafeMutablePointer(to: &waiting) { pointer in
                        ipc.pointee.receive(capability: receive, frame: pointer)
                    }
                }
                server.pointee.context = withUnsafeMutablePointer(to: &waiting) { $0 }

                withCurrentProcess(client) {
                    _ = ipc.pointee.send(capability: send, frame: frame(word: 7))
                }

                #expect(server.pointee.context?.pointee.x6 == session)

                // And the other register carries the sender, not the session.
                let principal = server.pointee.context?.pointee.x7 ?? 0
                #expect(IPCDelivery.identity(of: principal) == client.pointee.identity)
                #expect(IPCDelivery.grant(of: principal) == nil)
            }
        }
    }


    // MARK: - A message left waiting

    @Test("a queued send carries the whole session to whoever collects it")
    func queuedSend() {
        for session in Self.wide {
            withPair { ipc, endpoint, server, client in
                let receive = give(ipc, server, on: endpoint, [.receive])
                let send    = give(ipc, client, on: endpoint, [.send], session: session)

                // Nobody waiting, so the message is parked on the endpoint and
                // the session goes with it into `PendingMessage`.
                withCurrentProcess(client) {
                    _ = ipc.pointee.send(capability: send, frame: frame(word: 9))
                }

                var taken = Arch.TrapFrame()
                withCurrentProcess(server) {
                    _ = withUnsafeMutablePointer(to: &taken) { pointer in
                        ipc.pointee.receive(capability: receive, frame: pointer)
                    }
                }

                #expect(taken.x6 == session)
                #expect(IPCDelivery.identity(of: taken.x7) == client.pointee.identity)
            }
        }
    }


    // MARK: - A call

    @Test("a call carries the whole session and no capability")
    func callCarriesIt() {
        for session in Self.wide {
            withPair { ipc, endpoint, server, client in
                let receive = give(ipc, server, on: endpoint, [.receive])
                let send    = give(ipc, client, on: endpoint, [.send], session: session)

                var waiting = Arch.TrapFrame()
                withCurrentProcess(server) {
                    _ = withUnsafeMutablePointer(to: &waiting) { pointer in
                        ipc.pointee.receive(capability: receive, frame: pointer)
                    }
                }
                server.pointee.context = withUnsafeMutablePointer(to: &waiting) { $0 }

                withCurrentProcess(client) {
                    _ = ipc.pointee.call(capability: send, frame: frame(word: 11))
                }

                #expect(server.pointee.context?.pointee.x6 == session)

                // A call carries no capability, and the grant half says so rather
                // than being left at whatever the frame held.
                let principal = server.pointee.context?.pointee.x7 ?? 0
                #expect(IPCDelivery.grant(of: principal) == nil)
                #expect(IPCDelivery.identity(of: principal) == client.pointee.identity)
            }
        }
    }


    // MARK: - The answer

    @Test("a reply belongs to no conversation and says who answered")
    func replyCarriesNoSession() {
        withPair { ipc, endpoint, server, client in
            let receive = give(ipc, server, on: endpoint, [.receive])
            let send    = give(ipc, client, on: endpoint, [.send], session: 1 << 40)

            withCurrentProcess(client) {
                _ = ipc.pointee.call(capability: send, frame: frame(word: 13))
            }

            var taken = Arch.TrapFrame()
            withCurrentProcess(server) {
                _ = withUnsafeMutablePointer(to: &taken) { pointer in
                    ipc.pointee.receive(capability: receive, frame: pointer)
                }
            }

            #expect(taken.x6 == 1 << 40)

            withCurrentProcess(server) {
                _ = ipc.pointee.reply(frame: frame(word: 21))
            }

            // No session: the caller knows which question it asked, so a reply
            // belongs to no conversation of its own. The identity is the
            // server's, which is the one thing the caller could not have known.
            #expect(client.pointee.context?.pointee.x6 == 0)

            let principal = client.pointee.context?.pointee.x7 ?? 0
            #expect(IPCDelivery.identity(of: principal) == server.pointee.identity)
        }
    }


    // MARK: - A capability handed on

    @Test("a capability handed on keeps the session it was given")
    func grantsKeepTheSession() {
        for session in Self.wide {
            withPair { ipc, endpoint, server, client in
                let receive = give(ipc, server, on: endpoint, [.receive])

                // The one the client holds, badged. Handing it on copies the
                // badge unchanged: a session says which conversation, so a
                // capability that changed it on the way would be a different
                // conversation arriving under the same name.
                let badged = Capability(
                    target: .endpoint(endpoint),
                    badge : session,
                    rights: [.send, .grant]
                )
                let handle = client.pointee.metadata.pointee.capsTable.install(badged)
                ipc.pointee.retain(badged)

                guard let handle else {
                    Issue.record("no room for the capability")
                    return
                }

                var waiting = Arch.TrapFrame()
                withCurrentProcess(server) {
                    _ = withUnsafeMutablePointer(to: &waiting) { pointer in
                        ipc.pointee.receive(capability: receive, frame: pointer)
                    }
                }
                server.pointee.context = withUnsafeMutablePointer(to: &waiting) { $0 }

                var carrying = frame(word: 17)
                carrying.x6 = UInt64(handle)
                    | (UInt64(CapRights([.send]).rawValue) << 32)

                withCurrentProcess(client) {
                    _ = ipc.pointee.send(capability: badged, frame: carrying)
                }

                #expect(server.pointee.context?.pointee.x6 == session)

                guard let granted = IPCDelivery.grant(
                    of: server.pointee.context?.pointee.x7 ?? 0
                ) else {
                    Issue.record("the capability did not arrive")
                    return
                }

                let inherited = server.pointee.metadata.pointee.capsTable.resolve(granted)
                #expect(inherited?.badge == session)
            }
        }
    }
}
