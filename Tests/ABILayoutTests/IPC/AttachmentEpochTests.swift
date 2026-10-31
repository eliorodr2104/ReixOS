//
//  AttachmentEpochTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import Testing
import ReixABI

/// Which session a request belongs to, and what happens to the ones that
/// belonged to the last.
///
/// A server keyed its clients on identity and remembered where each one's page
/// was. Attaching again replaced the page, and nothing anywhere said that the
/// read already out with the disk had been asked for against the *other* one. So
/// the bytes landed in a window that had nothing to do with the request, and a
/// completion nobody had collected before the change was handed to the new
/// session as if it were its own answer.
///
/// One field fixes both, and the tests here are what say it is checked at each
/// of the places it has to be: before a copy, before a collect, and at the
/// moment of replacement.
@Suite("Attachment epochs")
struct AttachmentEpochTests {

    private static let page: UInt64 = 4096

    private func attachment(
        _ identity: UInt32,
          epoch   : UInt64,
          address : UInt64 = 0x4000_0000,
          pages   : UInt64 = 1,
          grant   : UInt32 = 30
    ) -> ShmAttachment {
        ShmAttachment(
            identity: identity,
            epoch   : epoch,
            address : address,
            extent  : pages * Self.page,
            grant   : grant
        )
    }


    // MARK: - Telling two attachments apart

    @Test("an identity on its own does not say which attachment")
    func identityIsNotEnough() {
        let second = attachment(7, epoch: 2)

        // The case the bug was: same client, same slot, different window.
        #expect(second.matches(identity: 7, epoch: 2))
        #expect(!second.matches(identity: 7, epoch: 1))
        #expect(!second.matches(identity: 9, epoch: 2))
        #expect(!second.matches(identity: 9, epoch: 1))
    }


    @Test("a window bounds what may be copied into it, without wrapping")
    func windowBounds() {
        let one = attachment(7, epoch: 1, pages: 1)

        #expect(one.covers(0, Self.page))
        #expect(one.covers(Self.page, 0))
        #expect(!one.covers(0, Self.page + 1))
        #expect(!one.covers(Self.page, 1))

        // The dangerous one: an offset near the top with a length that carries it
        // round, which every `offset + bytes <= extent` written the obvious way
        // accepts.
        #expect(!one.covers(UInt64.max, 8))
        #expect(!one.covers(UInt64.max - 4, 8))
    }


    @Test("a grant of anything but the pages asked for is refused")
    func pageCounts() {
        // The terminal takes exactly one. A client that granted none would have
        // its every read refused after the attach was already taken; one that
        // granted forty would have this server map forty pages because it asked.
        #expect(ShmAttachment.accepts(pages: 1, atMost: 1))
        #expect(!ShmAttachment.accepts(pages: 0, atMost: 1))
        #expect(!ShmAttachment.accepts(pages: 2, atMost: 1))
        #expect(!ShmAttachment.accepts(pages: UInt32.max, atMost: 1))

        // The block server takes up to four, one page per request in flight.
        #expect(ShmAttachment.accepts(pages: 4, atMost: 4))
        #expect(!ShmAttachment.accepts(pages: 5, atMost: 4))
        #expect(!ShmAttachment.accepts(pages: 0, atMost: 4))
    }


    @Test("epochs are handed out once each, and never zero")
    func epochsAreUnique() {
        var epochs = ShmAttachment.Epochs()

        #expect(epochs.current == 0)

        var previous = UInt64(0)
        for _ in 0..<1000 {
            guard let next = epochs.next() else {
                Issue.record("the epoch source ran out after a thousand")
                return
            }

            #expect(next > previous)
            previous = next
        }

        #expect(epochs.current == 1000)
    }


    // MARK: - Replacing an attachment

    @Test("ten thousand registrations hold one window and hand back the rest")
    func replacementLeaksNothing() {
        var slot = ShmAttachment.Slot()

        // A ledger of what the server would have mapped and not yet unmapped. The
        // rule under test is that `install` is the only way in and hands back
        // what it displaced, so a server cannot lose a window without losing the
        // one thing it was given to release.
        var live     = 0
        var released = 0
        var grants   = 0

        for round in 0..<10_000 {
            guard let epoch = slot.nextEpoch() else {
                Issue.record("the epoch source ran out at round \(round)")
                return
            }

            // Mapped, and owned: this is the point after which something is owed.
            live   += 1
            grants += 1

            if let displaced = slot.install(attachment(
                7, epoch: epoch, address: 0x4000_0000 + UInt64(round) * Self.page
            )) {
                #expect(displaced.epoch == epoch - 1)

                live     -= 1
                grants   -= 1
                released += 1
            }

            #expect(live == 1)
            #expect(grants == 1)
        }

        // And the last one goes back when the client is let go.
        if slot.take() != nil {
            live   -= 1
            grants -= 1
        }

        #expect(live == 0)
        #expect(grants == 0)
        #expect(released == 9_999)
        #expect(slot.current == nil)
    }


    @Test("a registration that fails after mapping keeps the one already held")
    func failureKeepsTheOld() {
        var slot = ShmAttachment.Slot()

        guard let first = slot.nextEpoch() else { Issue.record("no epoch"); return }
        #expect(slot.install(attachment(7, epoch: first, grant: 30)) == nil)

        // A second registration gets as far as a mapping and then stops - the
        // epoch source is exhausted, the map failed, the grant would not come
        // over. Whatever the reason, `install` was never reached, so the slot
        // still holds the first attachment and the caller still holds the new
        // mapping to undo.
        #expect(slot.current?.epoch == first)
        #expect(slot.current?.grant == 30)
        #expect(slot.held(by: 7))
        #expect(!slot.held(by: 9))

        // And when the second one does complete, the first comes back to be
        // released rather than being forgotten.
        guard let second = slot.nextEpoch() else { Issue.record("no epoch"); return }
        let displaced = slot.install(attachment(7, epoch: second, grant: 31))

        #expect(displaced?.epoch == first)
        #expect(displaced?.grant == 30)
        #expect(slot.current?.grant == 31)
    }

    @Test("a live reader refuses a different registration")
    func liveReaderOwnershipAdmission() {
        var slot = ShmAttachment.Slot()
        guard let first = slot.nextEpoch() else { Issue.record("no epoch"); return }
        _ = slot.install(attachment(7, epoch: first, grant: 30))

        #expect(slot.acceptsRegistration(identity: 7, currentIsLive: true))
        #expect(!slot.acceptsRegistration(identity: 9, currentIsLive: true))
        #expect(slot.acceptsRegistration(identity: 9, currentIsLive: false))
    }

    @Test("a live replacement distinguishes the former terminal token")
    func registrationTokenDistinguishesReplacement() {
        var slot = ShmAttachment.Slot()
        guard let first = slot.nextEpoch() else { Issue.record("no first epoch"); return }
        _ = slot.install(ShmAttachment(
            identity: 7, epoch: first, token: 70, address: 0x1000, extent: 4096, grant: 70
        ))
        guard let second = slot.nextEpoch() else { Issue.record("no second epoch"); return }
        _ = slot.install(ShmAttachment(
            identity: 7, epoch: second, token: 71, address: 0x2000, extent: 4096, grant: 71
        ))
        #expect(!slot.held(by: 7, token: 70))
        #expect(slot.held(by: 7, token: 71))
        #expect(slot.current?.matches(identity: 7, token: 71) == true)
    }


    // MARK: - Requests across a replacement

    private func pending(
        _ client: Int,
          _ identity: UInt32,
          epoch: UInt64,
          tag  : UInt32?,
          reads: Bool = true
    ) -> BlockRequests.Pending {
        BlockRequests.Pending(
            client: client, identity: identity, epoch: epoch,
            tag: tag, copiesBack: reads
        )
    }


    /// Reserves and submits, which is what a server does to put a request out
    /// with the device.
    @discardableResult
    private func out(
        _ requests: inout BlockRequests,
        _ slot: Int,
        _ pending: BlockRequests.Pending
    ) -> Bool {
        guard requests.reserve(slot, pending) else { return false }
        return requests.submitted(slot)
    }


    @Test("a request out with the device is not this session's after a reattach")
    func staleCompletionIsNotCopied() {
        var requests = BlockRequests()

        #expect(out(&requests, 0, pending(3, 7, epoch: 1, tag: 2)) == true)

        guard let owner = requests.owner(of: 0) else {
            Issue.record("the slot lost its owner")
            return
        }

        // The client attaches again, so the window is a different page. The
        // request is still out with the disk and its completion is still coming.
        let installed = attachment(7, epoch: 2, address: 0x5000_0000)

        #expect(owner.identity == 7)
        #expect(owner.client == 3)
        #expect(owner.epoch == 1)

        // This comparison is the whole fix. Without the epoch it reads as a
        // match, and the bytes go into the new session's page.
        #expect(!installed.matches(identity: owner.identity, epoch: owner.epoch))

        // And with the attachment it really was made against, it still is one.
        let before = attachment(7, epoch: 1)
        #expect(before.matches(identity: owner.identity, epoch: owner.epoch))
    }


    @Test("a reattach takes every request of the old attachment out of the table")
    func reattachAbandonsPending() {
        var requests = BlockRequests()

        // Four out: three of this client, one of another, and one of this
        // client's is a parked call rather than a `begin`.
        #expect(out(&requests, 0, pending(3, 7, epoch: 1, tag: 0)) == true)
        #expect(out(&requests, 1, pending(3, 7, epoch: 1, tag: 1)) == true)
        #expect(out(&requests, 2, pending(3, 7, epoch: 1, tag: nil)) == true)
        #expect(out(&requests, 3, pending(5, 9, epoch: 4, tag: 0)) == true)

        let taken = requests.abandon(epoch: 1, of: 7)

        #expect(taken[0])
        #expect(taken[1])
        #expect(taken[2])
        #expect(!taken[3])

        #expect(requests.owner(of: 0) == nil)
        #expect(requests.owner(of: 1) == nil)
        #expect(requests.owner(of: 2) == nil)

        // Somebody else's request is untouched: a client attaching again says
        // nothing about anybody but itself.
        #expect(requests.owner(of: 3)?.identity == 9)

        // And the new attachment is owed nothing at all.
        #expect(requests.outstanding(client: 3, identity: 7, epoch: 2) == false)
    }


    @Test("a completion from before a reattach is not collected by the new session")
    func staleResultIsNotCollected() {
        var requests = BlockRequests()

        #expect(requests.file(client: 3, identity: 7, epoch: 1, tag: 2, status: 0) == true)
        #expect(requests.waiting == 1)

        // The new session asks. There is nothing of its own to collect.
        #expect(requests.take(client: 3, identity: 7, epoch: 2) == nil)
        #expect(requests.outstanding(client: 3, identity: 7, epoch: 2) == false)

        // The old attachment's own answer is still findable, which is what makes
        // the discard below a deliberate act and not an accident of lookup.
        #expect(requests.take(client: 3, identity: 7, epoch: 1)
                == BlockRequests.Result(tag: 2, status: 0))

        // Discarding is what the reattach does, so nothing is left to find at
        // all - not by the old epoch and not by the new.
        #expect(requests.file(client: 3, identity: 7, epoch: 1, tag: 3, status: 0) == true)
        requests.discard(client: 3, epoch: 1)

        #expect(requests.waiting == 0)
        #expect(requests.take(client: 3, identity: 7, epoch: 1) == nil)
        #expect(requests.take(client: 3, identity: 7, epoch: 2) == nil)
    }


    @Test("letting a client go discards every attachment's answers, not one")
    func releaseDiscardsEveryEpoch() {
        var requests = BlockRequests()

        #expect(requests.file(client: 3, identity: 7, epoch: 1, tag: 0, status: 0) == true)
        #expect(requests.file(client: 3, identity: 7, epoch: 2, tag: 1, status: 0) == true)
        #expect(requests.file(client: 5, identity: 9, epoch: 1, tag: 0, status: 0) == true)

        requests.discard(client: 3, epoch: nil)

        #expect(requests.waiting == 1)
        #expect(requests.take(client: 5, identity: 9, epoch: 1)
                == BlockRequests.Result(tag: 0, status: 0))
    }


    @Test("one cell per name, so a second answer under a name is refused")
    func oneCellPerName() {
        var requests = BlockRequests()

        for tag in 0..<BlockRequests.tags {
            #expect(requests.file(
                client: 3, identity: 7, epoch: 1, tag: UInt32(tag), status: 0
            ) == true)
        }

        #expect(requests.held(by: 3) == BlockRequests.tags)

        // A second answer under a name that already has one. Refused rather
        // than filed somewhere else: the cells are not a pool, so there is no
        // somewhere else, which is the whole point of the table.
        #expect(requests.file(client: 3, identity: 7, epoch: 1, tag: 0, status: 0) == false)

        // Nothing already filed was evicted to make room.
        #expect(requests.waiting == BlockRequests.tags)

        // And this client filling its own names costs another client nothing.
        #expect(requests.file(client: 4, identity: 8, epoch: 1, tag: 0, status: 0) == true)
    }


    @Test("a slot is handed out once, and only within range")
    func reserveDiscipline() {
        var requests = BlockRequests()

        #expect(requests.reserve(0, pending(3, 7, epoch: 1, tag: 0)) == true)
        #expect(requests.reserve(0, pending(3, 7, epoch: 1, tag: 1)) == false)
        #expect(requests.reserve(-1, pending(3, 7, epoch: 1, tag: 0)) == false)
        #expect(requests.reserve(
            BlockRequests.slots, pending(3, 7, epoch: 1, tag: 0)
        ) == false)

        #expect(requests.owner(of: -1) == nil)
        #expect(requests.owner(of: BlockRequests.slots) == nil)

        // Reserved is not out with the device: an owner appears when the device
        // has actually been told.
        #expect(requests.state(slot: 0) == .reserved)
        #expect(requests.owner(of: 0) == nil)
        #expect(requests.submitted(0) == true)
        #expect(requests.state(slot: 0) == .inflight)
        #expect(requests.owner(of: 0)?.identity == 7)

        #expect(requests.finished(0)?.tag == 0)
        #expect(requests.state(slot: 0) == .idle)

        #expect(out(&requests, 0, pending(3, 7, epoch: 1, tag: 1)) == true)

        let lost = requests.abandonAll()
        #expect(lost[0])
        #expect(requests.owner(of: 0) == nil)
    }
}
