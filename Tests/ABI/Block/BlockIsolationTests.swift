//
//  BlockIsolationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI

/// One client cannot take the disk away from the others.
///
/// Two ways it could. The answers used to be a pool of four for everybody, so a
/// client that stopped collecting filled them, the next completion had nowhere to
/// be recorded, and the server's reaction to that was to reset the device and
/// fail every request every other client had outstanding. And the interrupt was
/// recognised by a *label*, which any process holding a capability to the
/// endpoint could stamp on a message of its own - so reading the transport's
/// registers and acknowledging the line were things a client could ask for.
///
/// The first is closed by the shape of the table: one cell per client per name,
/// so a client cannot be owed more answers than it has names, and a completion
/// always has somewhere to go. The second is closed by the type of the argument:
/// only a message the kernel wrote can produce a `KernelInterrupt`, and only a
/// `KernelInterrupt` reaches the handler.
@Suite("A block server one client cannot wedge")
struct BlockIsolationTests {

    private func pending(
        _ client: Int,
          _ identity: UInt32,
          epoch: UInt64,
          tag  : UInt32?
    ) -> BlockRequests.Pending {
        BlockRequests.Pending(
            client: client, identity: identity, epoch: epoch,
            tag: tag, copiesBack: true
        )
    }


    /// One whole request, from the server's point of view: named, reserved,
    /// submitted, completed, filed. `nil` when the name was refused, which is
    /// the throttle answering.
    private func round(
        _ requests: inout BlockRequests,
        client: Int,
        identity: UInt32,
        epoch: UInt64,
        tag: UInt32
    ) -> BlockStatus? {

        let room = requests.admits(client: client, tag: tag)
        guard room == .ok else { return room }

        guard let slot = free(&requests) else { return .queueFull }

        guard requests.reserve(
            slot, pending(client, identity, epoch: epoch, tag: tag)
        ) else { return .queueFull }

        guard requests.submitted(slot) else { return .deviceRefused }

        guard let done = requests.finished(slot) else { return .deviceRefused }

        guard requests.file(
            client  : done.client,
            identity: done.identity,
            epoch   : done.epoch,
            tag     : tag,
            status  : BlockStatus.ok.rawValue
        ) else { return .deviceRefused }

        return nil
    }


    /// A driver slot nothing is using, the way the device would answer.
    private func free(_ requests: inout BlockRequests) -> Int? {
        for slot in 0..<BlockRequests.slots where requests.state(slot: slot) == .idle {
            return slot
        }
        return nil
    }


    // MARK: - The hostile client

    @Test("ten thousand requests nobody collects cost the disk four")
    func hostileClientIsThrottledLocally() {
        var requests = BlockRequests()

        var accepted = 0
        var refused  = 0

        for step in 0..<10_000 {
            // Round the names, which is what a client asking as fast as it can
            // does. Every one after the first four finds its own answer waiting.
            let tag = UInt32(step % BlockRequests.tags)

            switch round(&requests, client: 0, identity: 7, epoch: 1, tag: tag) {
                case nil:
                    accepted += 1

                case .some(let why):
                    #expect(why == .duplicateTag, "step \(step): \(why)")
                    refused += 1
            }
        }

        // Four got through, one per name, and the other nine thousand nine
        // hundred and ninety-six never reached a driver slot.
        #expect(accepted == BlockRequests.perClient)
        #expect(refused == 10_000 - BlockRequests.perClient)
        #expect(requests.held(by: 0) == BlockRequests.perClient)

        // The count of them is the throttle's own report, and it is local: the
        // device was never told about any of them.
        #expect(requests.duplicateTags == UInt32(refused))

        // Nothing was lost and nothing arrived late, which is the difference
        // between refusing a request and losing an answer.
        #expect(requests.lateCompletions == 0)
        #expect(requests.waiting == BlockRequests.perClient)

        // And every driver slot is free, because none of the refused requests
        // ever took one.
        for slot in 0..<BlockRequests.slots {
            #expect(requests.state(slot: slot) == .idle, "slot \(slot)")
        }
    }


    @Test("a second client reads and writes throughout the first one's flood")
    func aSecondClientIsUnaffected() {
        var requests = BlockRequests()

        // The hostile one fills its four names and stops being served.
        for tag in 0..<BlockRequests.tags {
            #expect(round(
                &requests, client: 0, identity: 7, epoch: 1, tag: UInt32(tag)
            ) == nil)
        }

        var served = 0

        for step in 0..<2_000 {
            let tag = UInt32(step % BlockRequests.tags)

            // The hostile client asks again and is refused, every time.
            #expect(round(
                &requests, client: 0, identity: 7, epoch: 1, tag: tag
            ) == .duplicateTag)

            // And the second client goes round its own four names for ever,
            // because it collects what it asked for.
            guard round(&requests, client: 1, identity: 9, epoch: 1, tag: tag) == nil else {
                Issue.record("step \(step): the second client was refused")
                return
            }

            #expect(requests.take(client: 1, identity: 9, epoch: 1) != nil)
            served += 1
        }

        #expect(served == 2_000)

        // The flood is still exactly four answers, untouched by any of it.
        #expect(requests.held(by: 0) == BlockRequests.perClient)
        #expect(requests.lateCompletions == 0)
    }


    @Test("a name already spoken for is refused before a driver slot is taken")
    func duplicateTagIsRefusedBeforeTheDoorbell() {
        var requests = BlockRequests()

        let first = requests.admits(client: 2, tag: 1)
        #expect(first == .ok)
        #expect(requests.reserve(0, pending(2, 7, epoch: 1, tag: 1)) == true)

        // The same name again. Refused at the door, and the door is before the
        // device is told anything: no second driver slot moved.
        let again = requests.admits(client: 2, tag: 1)
        #expect(again == .duplicateTag)
        #expect(requests.reserve(1, pending(2, 7, epoch: 1, tag: 1)) == false)

        #expect(requests.state(slot: 1) == .idle)
        #expect(requests.duplicateTags == 1)

        // A different name of the same client is fine, and so is the same name
        // belonging to somebody else.
        #expect(requests.reserve(1, pending(2, 7, epoch: 1, tag: 2)) == true)
        #expect(requests.reserve(2, pending(3, 9, epoch: 1, tag: 1)) == true)

        // And a name outside the table is not a name.
        let wide = requests.admits(client: 2, tag: UInt32(BlockRequests.tags))
        #expect(wide == .tooLong)

        let stranger = requests.admits(client: BlockRequests.clients, tag: 0)
        #expect(stranger == .notAttached)
    }


    /// `begin` is a one-way send, so an admission refusal has to be an answer
    /// `collect` can take rather than a reply to the send.  It must take no
    /// driver slot, and it must leave no client waiting for an answer that the
    /// server has already decided not to produce.
    @Test("a one-way begin refusal is collected without taking a driver slot")
    func rejectedBeginIsCollected() {
        var requests = BlockRequests()

        let rejected = requests.reject(
            client: 2, identity: 71, epoch: 9, tag: 1,
            status: BlockStatus.queueFull.rawValue
        )

        #expect(rejected)
        #expect(requests.state(slot: 0) == .idle)
        #expect(requests.state(client: 2, tag: 1) == .done)
        #expect(requests.outstanding(client: 2, identity: 71, epoch: 9))
        #expect(requests.take(client: 2, identity: 71, epoch: 9)
            == BlockRequests.Result(tag: 1, status: BlockStatus.queueFull.rawValue))
        #expect(requests.state(client: 2, tag: 1) == .idle)
    }


    /// A hostile duplicate send is not allowed to turn a live request into a
    /// refusal.  The exact tag is the ownership boundary: its pending transfer
    /// remains live, its completion remains attributable, and the server has
    /// not changed either queue or cell state when rejecting the duplicate.
    @Test("a one-way duplicate cannot overwrite the live tagged request")
    func rejectedDuplicateKeepsLiveRequest() {
        var requests = BlockRequests()

        let reserved = requests.reserve(0, pending(1, 7, epoch: 4, tag: 2))
        #expect(reserved)
        let submitted = requests.submitted(0)
        #expect(submitted)

        let overwritten = requests.reject(
            client: 1, identity: 7, epoch: 4, tag: 2,
            status: BlockStatus.duplicateTag.rawValue
        )

        #expect(!overwritten)
        #expect(requests.state(slot: 0) == .inflight)
        #expect(requests.state(client: 1, tag: 2) == .inflight)
        #expect(requests.owner(of: 0)?.identity == 7)

        guard let completed = requests.finished(0) else {
            Issue.record("the live request was lost")
            return
        }
        let filed = requests.file(
            client: completed.client, identity: completed.identity,
            epoch: completed.epoch, tag: completed.tag!,
            status: BlockStatus.ok.rawValue
        )
        #expect(filed)
        #expect(requests.take(client: 1, identity: 7, epoch: 4)
            == BlockRequests.Result(tag: 2, status: BlockStatus.ok.rawValue))
    }


    /// The authorization gate runs before `begin`'s ordinary duplicate check.
    /// Repeating a denied one-way begin must neither replace the first exact
    /// refusal nor wedge the unrelated server state.
    @Test("a denied one-way duplicate preserves its first refusal")
    func deniedOneWayDuplicateIsOnlyCounted() {
        var requests = BlockRequests()

        let first = requests.fileRefusal(
            client: 3, identity: 91, epoch: 6, tag: 0,
            status: BlockStatus.notMounted.rawValue
        )
        #expect(first == .filed)

        let duplicate = requests.fileRefusal(
            client: 3, identity: 91, epoch: 6, tag: 0,
            status: BlockStatus.notMounted.rawValue
        )
        #expect(duplicate == .duplicate)
        #expect(requests.duplicateTags == 1)
        #expect(requests.state(client: 3, tag: 0) == .done)
        #expect(requests.take(client: 3, identity: 91, epoch: 6)
            == BlockRequests.Result(tag: 0, status: BlockStatus.notMounted.rawValue))
    }

    @Test("four queued requests keep two live clients isolated")
    func fourQueuedTwoClients() {
        var requests = BlockRequests()
        let owners: [(client: Int, identity: UInt32, tag: UInt32)] = [
            (0, 71, 0), (1, 89, 0), (0, 71, 1), (1, 89, 1),
        ]

        for (slot, owner) in owners.enumerated() {
            let admission = requests.admits(client: owner.client, tag: owner.tag)
            #expect(admission == .ok)
            let reserved = requests.reserve(
                slot,
                pending(owner.client, owner.identity, epoch: 3, tag: owner.tag)
            )
            #expect(reserved)
            let submitted = requests.submitted(slot)
            #expect(submitted)
        }

        for slot in 0..<BlockRequests.slots {
            #expect(requests.state(slot: slot) == .inflight)
        }
        #expect(requests.waiting == 0)
        #expect(requests.admits(client: 0, tag: 0) == .duplicateTag)
        #expect(requests.duplicateTags == 1)

        for slot in [1, 3, 0, 2] {
            guard let done = requests.finished(slot) else {
                Issue.record("slot \(slot) lost its owner")
                return
            }
            let filed = requests.file(
                client: done.client,
                identity: done.identity,
                epoch: done.epoch,
                tag: done.tag!,
                status: BlockStatus.ok.rawValue
            )
            #expect(filed)
        }

        #expect(requests.waiting == BlockRequests.slots)
        #expect(requests.take(client: 0, identity: 71, epoch: 3)?.tag == 0)
        #expect(requests.take(client: 1, identity: 89, epoch: 3)?.tag == 0)
        #expect(requests.take(client: 0, identity: 71, epoch: 3)?.tag == 1)
        #expect(requests.take(client: 1, identity: 89, epoch: 3)?.tag == 1)
        #expect(requests.waiting == 0)
        #expect(requests.lateCompletions == 0)
    }


    // MARK: - The four states

    @Test("the depth a client holds is its own asking, not the device's timing")
    func depthIsTheClientsAndNotTheDevices() {
        var requests = BlockRequests()

        #expect(requests.deepestHeld == 0)

        // One request taken all the way to a free driver slot: the device has
        // answered and the name is still spoken for, because nobody collected it.
        #expect(requests.reserve(0, pending(1, 7, epoch: 1, tag: 0)) == true)
        #expect(requests.deepestHeld == 1)
        #expect(requests.submitted(0) == true)

        guard let first = requests.finished(0) else {
            Issue.record("the completion found no owner")
            return
        }

        #expect(requests.file(
            client: first.client, identity: first.identity, epoch: first.epoch,
            tag: 0, status: 0
        ) == true)

        // Nothing is out with the device now, and that is the whole point: the
        // client's second request is still its second. The driver's own
        // high-water mark reads one here and would go on reading one for ever on
        // a device quick enough to answer between two submissions, which is what
        // made it a race to assert and this a fact to assert instead.
        #expect(requests.state(slot: 0) == .idle)
        #expect(requests.reserve(0, pending(1, 7, epoch: 1, tag: 1)) == true)
        #expect(requests.held(by: 1) == 2)
        #expect(requests.deepestHeld == 2)

        // And it is a high-water mark: taking both answers does not lower it.
        #expect(requests.submitted(0) == true)
        if let second = requests.finished(0) {
            #expect(requests.file(
                client: second.client, identity: second.identity,
                epoch: second.epoch, tag: 1, status: 0
            ) == true)
        }

        _ = requests.take(client: 1, identity: 7, epoch: 1)
        _ = requests.take(client: 1, identity: 7, epoch: 1)

        #expect(requests.held(by: 1) == 0)
        #expect(requests.deepestHeld == 2)
    }


    @Test("a request walks idle, reserved, inflight, done")
    func theFourStates() {
        var requests = BlockRequests()

        #expect(requests.state(client: 1, tag: 3) == .idle)
        #expect(requests.state(slot: 2) == .idle)

        #expect(requests.reserve(2, pending(1, 7, epoch: 4, tag: 3)) == true)
        #expect(requests.state(client: 1, tag: 3) == .reserved)
        #expect(requests.state(slot: 2) == .reserved)

        // Reserved is not out with the device, so it has no owner to answer.
        #expect(requests.owner(of: 2) == nil)

        #expect(requests.submitted(2) == true)
        #expect(requests.state(client: 1, tag: 3) == .inflight)
        #expect(requests.state(slot: 2) == .inflight)
        #expect(requests.owner(of: 2)?.epoch == 4)

        guard let done = requests.finished(2) else {
            Issue.record("the completion found no owner")
            return
        }

        // The driver slot is free the moment the completion is taken; the name
        // stays spoken for until its answer is collected.
        #expect(requests.state(slot: 2) == .idle)

        #expect(requests.file(
            client: done.client, identity: done.identity, epoch: done.epoch,
            tag: 3, status: 0
        ) == true)

        #expect(requests.state(client: 1, tag: 3) == .done)

        #expect(requests.take(client: 1, identity: 7, epoch: 4)
                == BlockRequests.Result(tag: 3, status: 0))

        #expect(requests.state(client: 1, tag: 3) == .idle)
    }


    @Test("an answer handed straight to a parked collector frees the name")
    func deliveredFreesTheName() {
        var requests = BlockRequests()

        #expect(requests.reserve(0, pending(1, 7, epoch: 1, tag: 0)) == true)
        #expect(requests.submitted(0) == true)
        #expect(requests.finished(0) != nil)

        // The client was already parked in `collect`, so the answer went to it
        // rather than into the cell. The name has to be free again or a client
        // that keeps four transfers going would stop after the first four.
        requests.delivered(client: 1, tag: 0)

        #expect(requests.state(client: 1, tag: 0) == .idle)

        let free = requests.admits(client: 1, tag: 0)
        #expect(free == .ok)
    }


    // MARK: - A submission that never happened

    @Test("a submit that fails puts back every reservation it took")
    func cancelRestoresEverything() {
        var requests = BlockRequests()

        #expect(requests.reserve(1, pending(2, 7, epoch: 3, tag: 2)) == true)
        #expect(requests.held(by: 2) == 1)

        requests.cancel(1)

        // Both halves, which is the point of there being one call: a cancel that
        // freed the driver slot and left the name held would cost the client that
        // name for the rest of the boot.
        #expect(requests.state(slot: 1) == .idle)
        #expect(requests.state(client: 2, tag: 2) == .idle)
        #expect(requests.held(by: 2) == 0)

        let reusable = requests.admits(client: 2, tag: 2)
        #expect(reusable == .ok)

        // And the slot and the name are both usable again, by the same client
        // and by anybody else.
        #expect(requests.reserve(1, pending(2, 7, epoch: 3, tag: 2)) == true)

        // A cancel of a slot that is already out with the device is not a cancel.
        #expect(requests.submitted(1) == true)
        requests.cancel(1)
        #expect(requests.state(slot: 1) == .inflight)
    }


    @Test("a completion for a slot nothing was expecting one on is discarded")
    func lateCompletionIsDiscarded() {
        var requests = BlockRequests()

        #expect(requests.reserve(0, pending(1, 7, epoch: 1, tag: 0)) == true)
        #expect(requests.submitted(0) == true)
        #expect(requests.finished(0) != nil)
        #expect(requests.lateCompletions == 0)

        // The same completion again, which is what a device that answers twice
        // does. The slot has no owner, and the owner it *would* be attributed to
        // is whoever holds the slot next.
        #expect(requests.finished(0) == nil)
        #expect(requests.lateCompletions == 1)

        // A slot that was reserved and cancelled is not out with the device
        // either, so a completion for it is late too.
        #expect(requests.reserve(0, pending(1, 7, epoch: 1, tag: 1)) == true)
        requests.cancel(0)
        #expect(requests.finished(0) == nil)
        #expect(requests.lateCompletions == 2)

        // And the next client to take that slot is not handed the stale answer.
        #expect(requests.reserve(0, pending(2, 9, epoch: 5, tag: 0)) == true)
        #expect(requests.submitted(0) == true)
        #expect(requests.owner(of: 0)?.identity == 9)
    }


    // MARK: - The interrupt nobody can forge

    private func tag(_ label: UInt32, words: Int = 1) -> MessageTag {
        MessageTag(packed: (UInt64(label) << 8) | UInt64(words))
    }

    @Test("only a message the kernel wrote is an interrupt")
    func forgedInterruptIsNotOne() {
        let real = tag(InterruptNotification.label)

        // What the kernel writes: the label, no sender, no session, no grant.
        #expect(InterruptNotification.fromKernel(
            tag: real, identity: 0, session: 0, grantedCap: nil
        ))

        // A process wearing the label. Process identities start at one, so this
        // is the difference that cannot be forged.
        #expect(!InterruptNotification.fromKernel(
            tag: real, identity: 1, session: 0, grantedCap: nil
        ))
        #expect(!InterruptNotification.fromKernel(
            tag: real, identity: 4_000_000_000, session: 0, grantedCap: nil
        ))

        // The kernel writes no session and attaches no page, so a message
        // carrying either is not one it wrote.
        #expect(!InterruptNotification.fromKernel(
            tag: real, identity: 0, session: BlockOperation.Badge.readOnly, grantedCap: nil
        ))
        #expect(!InterruptNotification.fromKernel(
            tag: real, identity: 0, session: 0, grantedCap: 3
        ))

        // And a label that is not the one is not one either, whoever sent it.
        #expect(!InterruptNotification.fromKernel(
            tag: tag(BlockOperation.read.rawValue), identity: 0,
            session: 0, grantedCap: nil
        ))

        // The label alone still answers what it always answered, which is why it
        // is not the check.
        #expect(InterruptNotification.names(real))
    }


    // MARK: - Authority, before anything else

    @Test("a badge nobody minted holds nothing, whatever it asks for")
    func unknownBadgeHoldsNothing() {
        for operation in [
            BlockOperation.attach, .geometry, .read, .write, .begin,
            .collect, .flush, .mount, .unmount, .reclaim
        ] {
            #expect(BlockAccess.check(
                operation, session: 0xDEAD_BEEF, holder: nil, caller: 7
            ) == .notAuthorised, "\(operation)")
        }
    }
}
