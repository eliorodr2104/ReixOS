//
//  InterruptBindTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Waiting for a device and for a request in the same place.
///
/// The last thing standing between a block driver and more than one request in
/// flight. `irqWait` parks the caller on the line and `receive` parks it on an
/// endpoint; a process is in one place at a time, so a driver could wait for work
/// or wait for its disk and never both. A queue of eight descriptors had no way
/// to be used, however carefully it was written.
///
/// What this suite is really checking is that adding a second way to be woken did
/// not weaken the promise the first one made: an interrupt that fires with nobody
/// listening is still not lost, because it was never the wake-up that stored it -
/// the bits in the set are the storage, and always were.
extension KernelPolicyTestRoot {
@Suite("Interrupts on an endpoint", .serialized)
struct InterruptBindTests {

    private func withFixture(
        _ body: (
            UnsafeMutablePointer<KernelIPC>,
            UnsafeMutablePointer<Endpoint>,
            UnsafeMutablePointer<InterruptSet>,
            UnsafeMutablePointer<Process>
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
        defer { ipc.deinitialize(count: 1); ipc.deallocate() }

        let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
        endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
        defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

        let set = UnsafeMutablePointer<InterruptSet>.allocate(capacity: 1)
        set.initialize(to: InterruptSet())
        defer {
            InterruptClaims.releaseAll(of: set)
            set.deinitialize(count: 1)
            set.deallocate()
        }

        let client = makeProcess(pid: 2)
        attachMetadata(to: client)

        let clientContext = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        clientContext.initialize(to: Arch.TrapFrame())
        client.pointee.context = clientContext

        defer {
            client.pointee.context = nil
            clientContext.deinitialize(count: 1)
            clientContext.deallocate()
            destroyMetadata(of: client)
            destroyProcess(client)
        }

        Self.other = client

        let driver = makeProcess(pid: 1)
        attachMetadata(to: driver)

        // A register frame of its own. `makeProcess` leaves it nil, and every
        // path here writes an answer into it: a notification is registers and
        // nothing else.
        let context = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
        context.initialize(to: Arch.TrapFrame())
        driver.pointee.context = context

        defer {
            driver.pointee.context = nil
            context.deinitialize(count: 1)
            context.deallocate()
            destroyMetadata(of: driver)
            destroyProcess(driver)
        }

        body(ipc, endpoint, set, driver)
    }


    /// A capability on `endpoint`, installed and retained the way a real one is.
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


    private func receiving(
        _ ipc     : UnsafeMutablePointer<KernelIPC>,
        _ process : UnsafeMutablePointer<Process>,
        _ listen  : Capability
    ) -> Result<CommunicationMessageResult, IPCError> {

        var outcome: Result<CommunicationMessageResult, IPCError>!

        withCurrentProcess(process) {
            outcome = ipc.pointee.receive(capability: listen, frame: scratch)
        }

        return outcome
    }

    /// A frame that is deliberately **not** the process's own `context`.
    ///
    /// The two are the same pointer for a process in the middle of a syscall, so
    /// a test that passes `context` as the frame cannot tell an answer written
    /// into the live frame from one written through the field. That difference
    /// was a real hang: the immediate path wrote through the field, the boot got
    /// as far as the first sector and stopped, and this suite said nothing.
    private static var scratchStorage = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)

    private var scratch: UnsafeMutablePointer<Arch.TrapFrame> {
        Self.scratchStorage
    }

    /// A second process, for the cases that need somebody other than the driver
    /// queued on the endpoint.
    nonisolated(unsafe) private static var other: UnsafeMutablePointer<Process>! = nil


    private func parked(_ process: UnsafeMutablePointer<Process>) -> Bool {
        if case .blockedOnReceive = process.pointee.status { return true }
        return false
    }


    // MARK: - Being woken by the device

    /// A line that fired before the driver came back round to `receive`. The bits
    /// are already in the set, so the answer is immediate: this is the case that
    /// makes the loop safe to write, because a driver must never park on a device
    /// that has already spoken.
    @Test("a receive finds a device that has already spoken, and does not park")
    func pendingIsAnsweredAtOnce() {
        withFixture { ipc, endpoint, set, driver in

            let listen = give(ipc, driver, on: endpoint, [.receive])
            ipc.pointee.bind(interrupts: set, to: endpoint)

            #expect(set.pointee.add(line: 42) != nil)
            set.pointee.pending = 1

            scratch.pointee = Arch.TrapFrame()
            _ = receiving(ipc, driver, listen)

            #expect(!parked(driver))

            // Read out of the frame the syscall was handed, which is the one the
            // registers come back in.
            #expect(scratch.pointee.x0 == IPCStatus.ok.rawValue)
            #expect(InterruptNotification.names(MessageTag(packed: scratch.pointee.x1)))
            #expect(scratch.pointee.x2 == 1)

            // And nothing was written through the process's `context` instead.
            #expect(driver.pointee.context?.pointee.x1 == 0)

            // Collected, not left to be read twice.
            #expect(set.pointee.pending == 0)

            // No sender, because there was none. A server that keys state on the
            // caller must not find one here.
            #expect(scratch.pointee.x6 == 0)
        }
    }


    @Test("a line that fires wakes a driver already parked in receive")
    func firingWakesTheParkedDriver() {
        withFixture { ipc, endpoint, set, driver in

            let listen = give(ipc, driver, on: endpoint, [.receive])
            ipc.pointee.bind(interrupts: set, to: endpoint)

            #expect(set.pointee.add(line: 42) != nil)

            _ = receiving(ipc, driver, listen)
            #expect(parked(driver))

            set.pointee.pending = 1
            let found = ipc.pointee.signal(set)

            #expect(found)
            #expect(!parked(driver))

            let tag = MessageTag(packed: driver.pointee.context!.pointee.x1)
            #expect(InterruptNotification.names(tag))
            #expect(InterruptNotification.lines(of: Message(from: driver.pointee.context!.pointee)) == 1)
            #expect(set.pointee.pending == 0)
        }
    }


    /// The promise that must survive. It was never the wake-up that stored the
    /// event, so a line firing into an empty room still leaves its bit behind.
    @Test("a line that fires with nobody listening is not lost")
    func nothingIsLost() {
        withFixture { ipc, endpoint, set, driver in

            let listen = give(ipc, driver, on: endpoint, [.receive])
            ipc.pointee.bind(interrupts: set, to: endpoint)

            #expect(set.pointee.add(line: 42) != nil)

            set.pointee.pending = 1
            let found = ipc.pointee.signal(set)

            // Nobody to tell, and the bit stays.
            #expect(!found)
            #expect(set.pointee.pending == 1)

            // And the driver, arriving afterwards, is told.
            scratch.pointee = Arch.TrapFrame()
            _ = receiving(ipc, driver, listen)

            #expect(!parked(driver))
            #expect(scratch.pointee.x2 == 1)
            #expect(set.pointee.pending == 0)
        }
    }


    /// An unbound set behaves exactly as it did before any of this: the bit waits
    /// for `irqWait`, and a `receive` on some endpoint knows nothing about it.
    @Test("a set nobody bound changes nothing about receive")
    func unboundIsUnchanged() {
        withFixture { ipc, endpoint, set, driver in

            let listen = give(ipc, driver, on: endpoint, [.receive])

            #expect(set.pointee.add(line: 42) != nil)
            set.pointee.pending = 1

            _ = receiving(ipc, driver, listen)

            #expect(parked(driver))
            #expect(set.pointee.pending == 1)
        }
    }


    // MARK: - Lifetime

    /// The link that outlives its owner if it is forgotten. The endpoint holds a
    /// back pointer so that `receive` costs one load instead of a table walk, and
    /// a set freed without clearing it would leave a `receive` reading memory
    /// that has been handed back.
    @Test("releasing a set clears the endpoint's pointer to it")
    func releaseUnbinds() {
        withFixture { ipc, endpoint, set, driver in

            give(ipc, driver, on: endpoint, [.receive])
            ipc.pointee.bind(interrupts: set, to: endpoint)

            #expect(endpoint.pointee.signals == set)
            #expect(set.pointee.notify == endpoint)

            ipc.pointee.unbind(interrupts: set)

            #expect(endpoint.pointee.signals == nil)
            #expect(set.pointee.notify == nil)
        }
    }


    /// Binding takes a reference, so the endpoint cannot be freed underneath the
    /// set, and giving it up hands that reference back.
    @Test("binding holds the endpoint, and unbinding lets it go")
    func bindingHoldsAReference() {
        withFixture { ipc, endpoint, set, driver in

            give(ipc, driver, on: endpoint, [.receive])
            let held = endpoint.pointee.references

            ipc.pointee.bind(interrupts: set, to: endpoint)
            #expect(endpoint.pointee.references == held + 1)

            ipc.pointee.unbind(interrupts: set)
            #expect(endpoint.pointee.references == held)
        }
    }


    /// Binding twice is a replacement, not a second place to knock: two would
    /// mean choosing between them on every interrupt, and the holder of a set is
    /// one driver with one loop.
    @Test("rebinding replaces, and does not leak the endpoint it left")
    func rebindingReplaces() {
        withFixture { ipc, first, set, driver in

            let second = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            second.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { second.deinitialize(count: 1); second.deallocate() }

            give(ipc, driver, on: first,  [.receive])
            give(ipc, driver, on: second, [.receive])

            let heldFirst = first.pointee.references

            ipc.pointee.bind(interrupts: set, to: first)
            ipc.pointee.bind(interrupts: set, to: second)

            #expect(set.pointee.notify == second)
            #expect(second.pointee.signals == set)

            // The one it left is no longer named and no longer held.
            #expect(first.pointee.signals == nil)
            #expect(first.pointee.references == heldFirst)
        }
    }

    /// The check that decides whether there is anybody to tell.
    ///
    /// An endpoint's queue holds whoever is parked on it, and that is not always
    /// a receiver: a client whose message nobody has taken yet is queued there
    /// too, blocked on *send*. Handing an interrupt notification to one of those
    /// would wake a process that is waiting to be heard, tell it the disk said
    /// something, and leave its message unsent.
    ///
    /// So the state is asked first, and this is the case that says so: without
    /// it every other test here still passes, because they all signal into an
    /// empty queue.
    @Test("an endpoint with a sender queued on it is not somebody to tell")
    func aQueuedSenderIsNotAReceiver() {
        withFixture { ipc, endpoint, set, driver in

            let client = Self.other!

            let speak = Capability(target: .endpoint(endpoint), badge: Badge(0), rights: [.send])
            _ = client.pointee.metadata.pointee.capsTable.install(speak)
            ipc.pointee.retain(speak)

            give(ipc, driver, on: endpoint, [.receive])
            ipc.pointee.bind(interrupts: set, to: endpoint)
            #expect(set.pointee.add(line: 42) != nil)

            // Nobody is receiving, so the client parks waiting to be heard.
            withCurrentProcess(client) {
                _ = ipc.pointee.send(capability: speak, frame: Arch.TrapFrame())
            }

            #expect(endpoint.pointee.state == .sendBlocked)

            set.pointee.pending = 1
            let found = ipc.pointee.signal(set)

            // Nobody to tell: a sender is not a receiver.
            #expect(!found)
            #expect(set.pointee.pending == 1)

            // And the client is untouched - still parked, still holding its
            // message, and not carrying an interrupt notification it never
            // asked for.
            #expect(endpoint.pointee.state == .sendBlocked)
            #expect(!InterruptNotification.names(MessageTag(packed: clientTag(client))))
        }
    }

    /// The tag register of a process's saved frame, or zero when it has none.
    private func clientTag(_ process: UnsafeMutablePointer<Process>) -> UInt64 {
        process.pointee.context?.pointee.x1 ?? 0
    }

}


}
