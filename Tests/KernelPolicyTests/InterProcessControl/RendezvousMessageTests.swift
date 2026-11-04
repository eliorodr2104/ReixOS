//
//  RendezvousMessageTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/11/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Passing a trap frame by address must preserve the whole IPC message.
///
/// Queued and waiting peers exercise both delivery paths. The fused reply
/// must read its message before receiving into the same frame.
extension KernelPolicyTestRoot {
@Suite("Messages cross by address", .serialized)
struct RendezvousMessageTests {

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


    private func frame(_ first: UInt32 = 0x1111_1111) -> Arch.TrapFrame {
        var trap = Arch.TrapFrame()
        trap.x1 = (4 << 8) | 3
        trap.x2 = UInt64(first)
        trap.x3 = 0x2222_2222
        trap.x4 = 0x3333_3333
        trap.x5 = 0x4444_4444
        trap.x6 = UInt64(UInt32.max)
        return trap
    }

    private func expectMessage(
        _ destination: UnsafeMutablePointer<Arch.TrapFrame>,
        first        : UInt32 = 0x1111_1111
    ) {
        #expect(destination.pointee.x1 == (4 << 8) | 3)
        #expect(destination.pointee.x2 == UInt64(first))
        #expect(destination.pointee.x3 == 0x2222_2222)
        #expect(destination.pointee.x4 == 0x3333_3333)
        #expect(destination.pointee.x5 == 0x4444_4444)
    }

    @Test("send delivers the whole message to a waiting receiver")
    func sendReachesAParkedReceiver() {
        withServerAndClients(1) { _, ipc, context, endpoint, server, clients in
            let listen = give(ipc, server, on: endpoint, [.receive])
            _ = give(ipc, clients[0], on: endpoint, [.send])
            withCurrentProcess(server) {
                #expect(parked(ipc.pointee.receive(capability: listen, frame: server.pointee.context!)))
            }
            withCurrentProcess(clients[0]) {
                var trap = frame()
                trap.x0 = 0
                SendSyscall.handle(frame: &trap, context: context)
                #expect(trap.x0 == IPCStatus.ok.rawValue)
            }
            expectMessage(server.pointee.context!)
        }
    }

    @Test("receive takes the whole message from a queued sender")
    func aParkedSendIsReceivedWhole() {
        withServerAndClients(1) { _, ipc, _, endpoint, server, clients in
            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            withCurrentProcess(clients[0]) {
                var trap = frame()
                #expect(parked(ipc.pointee.send(capability: speak, frame: &trap)))
            }
            withCurrentProcess(server) {
                var taken = Arch.TrapFrame()
                #expect(delivered(ipc.pointee.receive(capability: listen, frame: &taken)))
                expectMessage(&taken)
            }
        }
    }

    @Test("call delivers the whole message to a waiting receiver")
    func callReachesAParkedReceiver() {
        withServerAndClients(1) { _, ipc, _, endpoint, server, clients in
            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            withCurrentProcess(server) {
                #expect(parked(ipc.pointee.receive(capability: listen, frame: server.pointee.context!)))
            }
            withCurrentProcess(clients[0]) {
                var trap = frame()
                #expect(parked(ipc.pointee.call(capability: speak, frame: &trap)))
            }
            expectMessage(server.pointee.context!)
        }
    }

    @Test("receive takes the whole message from a queued caller")
    func aParkedCallIsReceivedWhole() {
        withServerAndClients(1) { _, ipc, _, endpoint, server, clients in
            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            withCurrentProcess(clients[0]) {
                var trap = frame()
                #expect(parked(ipc.pointee.call(capability: speak, frame: &trap)))
            }
            withCurrentProcess(server) {
                var taken = Arch.TrapFrame()
                #expect(delivered(ipc.pointee.receive(capability: listen, frame: &taken)))
                expectMessage(&taken)
            }
        }
    }

    @Test("reply carries the whole message back to the caller")
    func replyCarriesTheWholeMessage() {
        withServerAndClients(1) { _, ipc, context, endpoint, server, clients in
            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            withCurrentProcess(clients[0]) {
                var trap = frame()
                #expect(parked(ipc.pointee.call(capability: speak, frame: &trap)))
            }
            withCurrentProcess(server) {
                #expect(delivered(ipc.pointee.receive(capability: listen, frame: server.pointee.context!)))
                var trap = frame(0xAAAA_AAAA)
                ReplySyscall.handle(frame: &trap, context: context)
                #expect(trap.x0 == IPCStatus.ok.rawValue)
            }
            expectMessage(clients[0].pointee.context!, first: 0xAAAA_AAAA)
        }
    }

    @Test("replyRecv replies before receiving into the same frame")
    func replyRecvAnswersBeforeItReceives() {
        withServerAndClients(2) { _, ipc, context, endpoint, server, clients in
            let listen = give(ipc, server, on: endpoint, [.receive])
            let speak  = give(ipc, clients[0], on: endpoint, [.send])
            _ = give(ipc, clients[1], on: endpoint, [.send])
            withCurrentProcess(clients[0]) {
                var trap = frame()
                #expect(parked(ipc.pointee.call(capability: speak, frame: &trap)))
            }
            withCurrentProcess(server) {
                #expect(delivered(ipc.pointee.receive(capability: listen, frame: server.pointee.context!)))
            }
            withCurrentProcess(clients[1]) {
                var trap = frame(0xBBBB_BBBB)
                #expect(parked(ipc.pointee.call(capability: speak, frame: &trap)))
            }
            withCurrentProcess(server) {
                var trap = frame(0xAAAA_AAAA)
                trap.x0 = 0
                ReplyRecvSyscall.handle(frame: &trap, context: context)
                #expect(trap.x0 == IPCStatus.ok.rawValue)
                expectMessage(&trap, first: 0xBBBB_BBBB)
            }
            expectMessage(clients[0].pointee.context!, first: 0xAAAA_AAAA)
        }
    }

    private func parked(_ result: Result<CommunicationMessageResult, IPCError>) -> Bool {
        if case .success(.blocked) = result { return true }
        return false
    }

    private func delivered(_ result: Result<CommunicationMessageResult, IPCError>) -> Bool {
        if case .success(.sended(let rejected)) = result { return !rejected }
        return false
    }
}
}
