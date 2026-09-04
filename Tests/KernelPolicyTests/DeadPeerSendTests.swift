//
//  DeadPeerSendTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// What happens to a message sent where nobody can receive it.
///
/// A blocking send agrees to wait for somebody to arrive. It used to agree to
/// that without checking whether anybody could: a request to a server that had
/// already died was queued on its endpoint and waited for the rest of the boot,
/// which is how one shell command after a file system crash wedged the shell for
/// good. `severReplyLinks` only ever covered the other case, a request already
/// in flight when its server died.
///
/// The fix is a count of the capabilities on an endpoint that carry `.receive`,
/// and the reason it is a *count* is the case in `senderIsTheOnlyReceiver`
/// below: an endpoint really can have more than one process able to receive on
/// it, so "the receiver died" has no answer while "nobody is left who could
/// serve me" does.
extension KernelPolicyTestRoot {
@Suite("Sending where nobody can receive")
struct DeadPeerSendTests {

    /// One IPC, one endpoint, and `processes` processes each with a caps table.
    ///
    /// The collaborators are zeroed storage, the same way the fork suite builds
    /// them: the paths under test queue on an endpoint, count capabilities and
    /// walk a caps table, and the only one that reaches the scheduler is the
    /// resume of an abandoned sender, which a zeroed round-robin serves.
    private func withFixture(
        processes count: Int,
        _ body: (
            UnsafeMutablePointer<KernelIPC>,
            UnsafeMutablePointer<Endpoint>,
            [UnsafeMutablePointer<Process>]
        ) -> Void
    ) {
        let ppm       = allocateZeroedStorage(KernelPPM.self)
        let scheduler = allocateZeroedStorage(KernelScheduler.self)
        let heap      = allocateZeroedStorage(KernelHeap.self)
        defer {
            UnsafeMutableRawPointer(ppm).deallocate()
            UnsafeMutableRawPointer(scheduler).deallocate()
            UnsafeMutableRawPointer(heap).deallocate()
        }

        let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
        ipc.initialize(to: KernelIPC(ppm: ppm, scheduler: scheduler, heap: heap))
        defer {
            ipc.deinitialize(count: 1)
            ipc.deallocate()
        }

        let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
        endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
        defer {
            endpoint.deinitialize(count: 1)
            endpoint.deallocate()
        }

        let processes = (1...count).map { pid -> UnsafeMutablePointer<Process> in
            let process = makeProcess(pid: PID(pid))
            attachMetadata(to: process)
            return process
        }
        defer {
            for process in processes {
                destroyMetadata(of: process)
                destroyProcess(process)
            }
        }

        body(ipc, endpoint, processes)
    }


    /// Installs a capability on `endpoint` in `process` and retains it, which is
    /// what every real install does and what keeps the receiver count honest.
    @discardableResult
    private func give(
        _ ipc     : UnsafeMutablePointer<KernelIPC>,
        _ process : UnsafeMutablePointer<Process>,
        on endpoint: UnsafeMutablePointer<Endpoint>,
        _ rights  : CapRights
    ) -> (handle: UInt32, capability: Capability) {

        let capability = Capability(
            target: .endpoint(endpoint),
            badge : Badge(0),
            rights: rights
        )

        let handle = process.pointee.metadata.pointee.capsTable.install(capability)!
        ipc.pointee.retain(capability)

        return (handle, capability)
    }


    private func attempt(
        _ ipc    : UnsafeMutablePointer<KernelIPC>,
        _ process: UnsafeMutablePointer<Process>,
        _ send   : Capability,
        calling  : Bool = false
    ) -> Result<CommunicationMessageResult, IPCError> {

        var outcome: Result<CommunicationMessageResult, IPCError>!

        withCurrentProcess(process) {
            outcome = calling
                ? ipc.pointee.call(capability: send, frame: Arch.TrapFrame())
                : ipc.pointee.send(capability: send, frame: Arch.TrapFrame())
        }

        return outcome
    }


    // MARK: - The count itself

    @Test("only the capabilities that can receive are counted as receivers")
    func onlyReceiveRightsCount() {
        withFixture(processes: 2) { ipc, endpoint, processes in
            give(ipc, processes[0], on: endpoint, [.send])
            #expect(endpoint.pointee.receivers == 0)
            #expect(endpoint.pointee.references == 1)

            give(ipc, processes[1], on: endpoint, [.send, .receive])
            #expect(endpoint.pointee.receivers == 1)
            #expect(endpoint.pointee.references == 2)
        }
    }


    @Test("giving a capability back takes its receiver back with it")
    func releaseUncountsTheReceiver() {
        withFixture(processes: 2) { ipc, endpoint, processes in
            // A client holding a plain send capability, so the endpoint keeps a
            // reference and is not freed out from under the assertion. That is
            // the shape of every real server anyway: the clients outlive it.
            give(ipc, processes[0], on: endpoint, [.send])

            let given = give(ipc, processes[1], on: endpoint, [.send, .receive])
            #expect(endpoint.pointee.receivers == 1)

            _ = ipc.pointee.releaseCapability(given.handle, of: processes[1])

            #expect(endpoint.pointee.receivers  == 0)
            #expect(endpoint.pointee.references == 1)
        }
    }


    // MARK: - Refusing rather than parking

    @Test("a send to an endpoint nobody can receive on is refused, not queued")
    func sendToNobodyIsRefused() {
        withFixture(processes: 1) { ipc, endpoint, processes in
            let send = give(ipc, processes[0], on: endpoint, [.send]).capability

            let outcome = attempt(ipc, processes[0], send)

            guard case .failure(let error) = outcome else {
                Issue.record("a send with no possible receiver was accepted")
                return
            }

            #expect(error.status == .peerDied)
            #expect(endpoint.pointee.queue.isEmpty())
            #expect(processes[0].pointee.pending == nil)
        }
    }


    @Test("a call to a server that has gone is refused, not queued")
    func callToNobodyIsRefused() {
        // The reported bug, at its own level: the shell asking a file system
        // that died a command ago. It used to be parked here for good.
        withFixture(processes: 1) { ipc, endpoint, processes in
            let send = give(ipc, processes[0], on: endpoint, [.send]).capability

            let outcome = attempt(ipc, processes[0], send, calling: true)

            guard case .failure(let error) = outcome else {
                Issue.record("a call with no possible receiver was accepted")
                return
            }

            #expect(error.status == .peerDied)
            #expect(endpoint.pointee.queue.isEmpty())
        }
    }


    @Test("a send still waits while somebody else could serve it")
    func sendWaitsWhileAReceiverExists() {
        // The refusal must not swallow ordinary backpressure: a server that is
        // busy rather than gone is exactly what a blocking send is for.
        withFixture(processes: 2) { ipc, endpoint, processes in
            let send = give(ipc, processes[0], on: endpoint, [.send]).capability
            give(ipc, processes[1], on: endpoint, [.send, .receive])

            let outcome = attempt(ipc, processes[0], send)

            guard case .success(.blocked) = outcome else {
                Issue.record("a send that could still be served was refused")
                return
            }

            #expect(!endpoint.pointee.queue.isEmpty())
            #expect(endpoint.pointee.state == .sendBlocked)
        }
    }


    @Test("holding the only receiver yourself is the same as there being none")
    func senderIsTheOnlyReceiver() {
        // This is why the check is not `receivers > 0`. Every spawn builds this
        // shape: the endpoint between a parent and its child gives *both* sides
        // `.receive`, so after the child dies the count still says one, and that
        // one is the parent doing the sending. A process cannot answer its own
        // blocking send.
        withFixture(processes: 1) { ipc, endpoint, processes in
            let mine = give(ipc, processes[0], on: endpoint, [.send, .receive])
            #expect(endpoint.pointee.receivers == 1)

            let outcome = attempt(ipc, processes[0], mine.capability)

            guard case .failure(let error) = outcome else {
                Issue.record("a process was left waiting for itself")
                return
            }

            #expect(error.status == .peerDied)
        }
    }


    // MARK: - Letting go of whoever is already queued

    @Test("a sender already queued is let go when its last receiver goes away")
    func queuedSenderIsAbandoned() {
        withFixture(processes: 2) { ipc, endpoint, processes in
            let sender   = processes[0]
            let receiver = processes[1]

            let send = give(ipc, sender, on: endpoint, [.send]).capability
            let held = give(ipc, receiver, on: endpoint, [.send, .receive])

            guard case .success(.blocked) = attempt(ipc, sender, send) else {
                Issue.record("the sender did not queue in the first place")
                return
            }

            let context = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            context.initialize(to: Arch.TrapFrame())
            defer { context.deinitialize(count: 1); context.deallocate() }

            sender.pointee.context = context

            // The receiver dies, which is this one line: its capabilities go.
            _ = ipc.pointee.releaseCapability(held.handle, of: receiver)

            #expect(endpoint.pointee.receivers == 0)
            #expect(endpoint.pointee.queue.isEmpty())
            #expect(endpoint.pointee.state == .idle)

            #expect(context.pointee.x0 == IPCStatus.peerDied.rawValue)
            #expect(sender.pointee.pending == nil)

            if case .blockedOnSend = sender.pointee.status {
                Issue.record("an abandoned sender was left blocked on the endpoint")
            }
        }
    }


    @Test("a queued sender stays queued while another receiver is left")
    func queuedSenderSurvivesOneOfTwoReceivers() {
        withFixture(processes: 3) { ipc, endpoint, processes in
            let send  = give(ipc, processes[0], on: endpoint, [.send]).capability
            let first = give(ipc, processes[1], on: endpoint, [.send, .receive])
            give(ipc, processes[2], on: endpoint, [.send, .receive])

            guard case .success(.blocked) = attempt(ipc, processes[0], send) else {
                Issue.record("the sender did not queue in the first place")
                return
            }

            _ = ipc.pointee.releaseCapability(first.handle, of: processes[1])

            // One receiver left, so the wait is still a wait and not a wedge.
            #expect(endpoint.pointee.receivers == 1)
            #expect(!endpoint.pointee.queue.isEmpty())
            #expect(endpoint.pointee.state == .sendBlocked)
        }
    }
}


}
