//
//  DeferredReplyTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// A server holding more than one request at once.
///
/// This was impossible, in one line: a server had a single `replyTo` pointer,
/// and a second caller arriving *broke* the first, resuming it with `noReply`.
/// Everything that wanted more than one request in flight - a block driver with
/// eight descriptors, a file system that could take a second request while the
/// disk was busy, a compaction that could be interrupted - was blocked behind
/// that pointer, so it is the first thing to change and this suite is what says
/// it changed.
///
/// The link that does the work is the one on the *waiter*: `replyPartner` names
/// the server it is waiting on, every waiter has one, and the set of callers on a
/// server is exactly the set of processes pointing at it. So there is no table,
/// nothing allocated per outstanding request, and the walk that finds them is the
/// process tree - the one enumeration that sees a process wherever it is parked.
@Suite("Deferred replies", .serialized)
struct DeferredReplyTests {

    /// A manager, an endpoint, one server and `clients` clients, all in the tree
    /// so that the walk behind `reply(to:)` can see them.
    private func withServerAndClients(
        _ clients: Int,
        _ body: (
            UnsafeMutablePointer<ProcessManager>,
            UnsafeMutablePointer<KernelIPC>,
            SyscallContext,
            UnsafeMutablePointer<Endpoint>,
            UnsafeMutablePointer<Process>,
            [UnsafeMutablePointer<Process>]
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

            guard let server = try? manager.pointee.spawnProcess() else {
                Issue.record("could not spawn the server")
                return
            }

            var callers: [UnsafeMutablePointer<Process>] = []

            for _ in 0..<clients {
                guard let client = try? manager.pointee.spawnProcess() else {
                    Issue.record("could not spawn a client")
                    return
                }
                callers.append(client)
            }

            body(manager, ipc, SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            ), endpoint, server, callers)
        }
    }


    /// A capability on `endpoint`, installed and retained the way a real one is,
    /// so the endpoint's receiver count stays honest.
    @discardableResult
    private func give(
        _ ipc      : UnsafeMutablePointer<KernelIPC>,
        _ process  : UnsafeMutablePointer<Process>,
        on endpoint: UnsafeMutablePointer<Endpoint>,
        _ rights   : CapRights
    ) -> Capability {

        let capability = Capability(
            target: .endpoint(endpoint),
            badge : Badge(0),
            rights: rights
        )

        _ = process.pointee.metadata.pointee.capsTable.install(capability)
        ipc.pointee.retain(capability)

        return capability
    }


    /// `ProcessStatus` carries a payload on two of its cases, so it is not
    /// `Equatable` and a plain `==` will not compile.
    private func awaitingReply(_ process: UnsafeMutablePointer<Process>) -> Bool {
        if case .blockedOnReply = process.pointee.status { return true }
        return false
    }


    /// One word in, so a reply can be told apart from another reply. The tag is
    /// packed by hand because `MessageTag` takes an `IPCLabel` and this suite has
    /// no protocol, only a number to look for on the other side.
    private func frame(word: UInt32, identity: UInt32 = 0) -> Arch.TrapFrame {
        var trap = Arch.TrapFrame()
        trap.x0 = UInt64(identity)
        trap.x1 = (UInt64(1) << 8) | 1   // one word, label one
        trap.x2 = UInt64(word)
        trap.x6 = UInt64(UInt32.max)   // no grant

        return trap
    }


    /// Puts `client` in a call on `endpoint`, then has `server` take it.
    private func exchange(
        _ ipc     : UnsafeMutablePointer<KernelIPC>,
        from client: UnsafeMutablePointer<Process>,
        to server : UnsafeMutablePointer<Process>,
        _ send    : Capability,
        _ receive : Capability,
        word      : UInt32
    ) {
        withCurrentProcess(client) {
            _ = ipc.pointee.call(capability: send, frame: frame(word: word))
        }

        withCurrentProcess(server) {
            var trap = Arch.TrapFrame()
            _ = withUnsafeMutablePointer(to: &trap) { pointer in
                ipc.pointee.receive(capability: receive, frame: pointer)
            }
        }
    }


    // MARK: - The thing that was impossible

    @Test("a second caller no longer breaks the first")
    func theFirstCallerSurvives() {
        withServerAndClients(2) { _, ipc, _, endpoint, server, clients in

            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            _ = give(ipc, clients[1], on: endpoint, [.send])

            exchange(ipc, from: clients[0], to: server, speak, listen, word: 11)

            #expect(awaitingReply(clients[0]))
            #expect(server.pointee.replyTo == clients[0])
            #expect(server.pointee.deferredReplies == 0)

            exchange(ipc, from: clients[1], to: server, speak, listen, word: 22)

            // The whole point. The first caller is still asleep waiting for its
            // answer, and still linked to the server, where it used to have been
            // woken with `noReply` the moment this second call arrived.
            #expect(awaitingReply(clients[0]))
            #expect(clients[0].pointee.replyPartner == server)
            #expect(clients[0].pointee.context?.pointee.x0 != IPCStatus.noReply.rawValue)

            #expect(server.pointee.replyTo == clients[1])
            #expect(server.pointee.deferredReplies == 1)
        }
    }


    @Test("both callers get their own answer, oldest first")
    func bothAreAnswered() {
        withServerAndClients(2) { manager, ipc, context, endpoint, server, clients in

            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            _ = give(ipc, clients[1], on: endpoint, [.send])

            exchange(ipc, from: clients[0], to: server, speak, listen, word: 11)
            exchange(ipc, from: clients[1], to: server, speak, listen, word: 22)

            // The older caller, named. Nothing else can reach it: it is not in
            // `replyTo` any more.
            let older = clients[0].pointee.identity

            withCurrentProcess(server) {
                var trap = frame(word: 111, identity: older)
                withUnsafeMutablePointer(to: &trap) { pointer in
                    ReplySyscall.handle(frame: pointer, context: context)
                    #expect(pointer.pointee.x0 == IPCStatus.ok.rawValue)
                }
            }

            #expect(clients[0].pointee.context?.pointee.x2 == 111)
            #expect(clients[0].pointee.replyPartner == nil)

            // And the newer one is still where it was, reachable without a name.
            #expect(server.pointee.replyTo == clients[1])
            #expect(server.pointee.deferredReplies == 0)
            #expect(awaitingReply(clients[1]))

            withCurrentProcess(server) {
                var trap = frame(word: 222)
                withUnsafeMutablePointer(to: &trap) { pointer in
                    ReplySyscall.handle(frame: pointer, context: context)
                    #expect(pointer.pointee.x0 == IPCStatus.ok.rawValue)
                }
            }

            #expect(clients[1].pointee.context?.pointee.x2 == 222)
            #expect(server.pointee.replyTo == nil)

            // Each got its own words and not the other's.
            #expect(clients[0].pointee.context?.pointee.x2 == 111)
        }
    }


    // MARK: - Naming the wrong caller

    /// A name that is not waiting on this server is refused, not redirected. A
    /// reply delivered to the wrong client is worse than one not delivered: the
    /// client would take another request's answer as its own.
    @Test("a server cannot answer somebody who is not waiting on it")
    func onlyItsOwnCallers() {
        withServerAndClients(2) { _, ipc, context, endpoint, server, clients in

            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])

            exchange(ipc, from: clients[0], to: server, speak, listen, word: 11)

            // A process that exists and is not waiting on anybody.
            let stranger = clients[1].pointee.identity

            for name in [stranger, 0xDEAD_BEEF, server.pointee.identity] {
                withCurrentProcess(server) {
                    var trap = frame(word: 999, identity: name)
                    withUnsafeMutablePointer(to: &trap) { pointer in
                        ReplySyscall.handle(frame: pointer, context: context)
                        #expect(pointer.pointee.x0 == IPCStatus.noReply.rawValue)
                    }
                }
            }

            // And the caller that really is waiting was left alone: no words of
            // somebody else's reply landed on it, and it is still asleep.
            #expect(awaitingReply(clients[0]))
            #expect(clients[0].pointee.context?.pointee.x2 != 999)
            #expect(server.pointee.replyTo == clients[0])
        }
    }


    // MARK: - The bound

    /// Holding callers is bounded, because holding them for ever is worse than
    /// telling one its call was dropped. Past the bound the old behaviour comes
    /// back, on the oldest caller, with the status it always used.
    @Test("a server that never answers stops holding callers at the bound")
    func theBoundHolds() {
        let limit = Int(RendezvousIPC.deferredReplyLimit)

        withServerAndClients(limit + 2) { _, ipc, _, endpoint, server, clients in

            let listen = give(ipc, server, on: endpoint, [.receive])

            for client in clients {
                let speak = give(ipc, client, on: endpoint, [.send])
                exchange(ipc, from: client, to: server, speak, listen, word: 7)
            }

            // The bound, and not one more.
            #expect(server.pointee.deferredReplies == RendezvousIPC.deferredReplyLimit)

            // And it is the *oldest* caller that was let go of, told the same
            // thing every displaced caller was told before any of this existed.
            //
            // Which one matters as much as how many. Dropping a recent caller
            // instead would leave the oldest held for ever, which is the exact
            // failure the bound exists to prevent.
            #expect(clients[0].pointee.context?.pointee.x0 == IPCStatus.noReply.rawValue)
            #expect(clients[0].pointee.replyPartner == nil)
            #expect(!awaitingReply(clients[0]))

            var dropped = 0
            for client in clients where
                client.pointee.context?.pointee.x0 == IPCStatus.noReply.rawValue {
                dropped += 1
            }

            #expect(dropped == clients.count - limit - 1)

            // Everybody else is still waiting, newest included.
            for client in clients.dropFirst(dropped) {
                #expect(awaitingReply(client))
                #expect(client.pointee.replyPartner == server)
            }
        }
    }


    // MARK: - Death

    /// The reason the death path had to change too. A server holding several
    /// callers used to be unhooked from the one in `replyTo` only, so the rest
    /// would have stayed asleep on a process that no longer exists - a hang
    /// outliving the thing that caused it.
    @Test("a server that dies wakes everybody it owed an answer to")
    func deathWakesThemAll() {
        withServerAndClients(3) { manager, ipc, context, endpoint, server, clients in

            let listen = give(ipc, server, on: endpoint, [.receive])

            for client in clients {
                let speak = give(ipc, client, on: endpoint, [.send])
                exchange(ipc, from: client, to: server, speak, listen, word: 5)
            }

            #expect(server.pointee.deferredReplies == 2)

            for client in clients {
                #expect(awaitingReply(client))
            }

            _ = manager.pointee.killProcess(server, reason: .exited(0), context: context)

            for client in clients {
                #expect(client.pointee.replyPartner == nil)
                #expect(client.pointee.context?.pointee.x0 == IPCStatus.peerDied.rawValue)
            }
        }
    }
}
