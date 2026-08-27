//
//  PipeProtocolTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import Testing
import ReixABI

@Suite("Bounded blob transfer")
struct PipeProtocolTests {

    private func attachment(_ epoch: UInt64, _ grant: UInt32) -> ShmAttachment {
        ShmAttachment(
            identity: 7,
            epoch: epoch,
            address: 0x4000_0000 + epoch * 4096,
            extent: 4096,
            grant: grant
        )
    }

    @Test("frame counts are bounded by mapping and destination")
    func countBounds() {
        let page = UInt64(4096)

        #expect(PipeFrame(count: 4096, flags: 0)?.checked(
            extent: page, destinationCapacity: 4096, ended: false
        ) == .ok)
        #expect(PipeFrame(count: 4097, flags: 0)?.checked(
            extent: page, destinationCapacity: 4097, ended: false
        ) == .outOfBounds)
        #expect(PipeFrame(rawCount: UInt32.max, flags: 0).checked(
            extent: page, destinationCapacity: 4096, ended: false
        ) == .outOfBounds)
        #expect(PipeFrame(count: 1, flags: 0)?.checked(
            extent: page, destinationCapacity: -1, ended: false
        ) == .destinationTooSmall)
    }

    @Test("only an exact acknowledgement completes a frame")
    func acknowledgementMustMatch() {
        guard let frame = PipeFrame(count: 4096, flags: 0) else {
            Issue.record("frame")
            return
        }

        #expect(PipeAcknowledgement(count: 4096, status: .ok, flags: 0).accepts(frame))
        #expect(!PipeAcknowledgement(count: 4095, status: .ok, flags: 0).accepts(frame))
        #expect(!PipeAcknowledgement(count: 4096, status: .outOfBounds, flags: 0).accepts(frame))
        #expect(!PipeAcknowledgement(count: 4096, status: .ok, flags: PipeFrame.endFlag).accepts(frame))
    }

    @Test("end is acknowledged in a frame and cannot be repeated")
    func endIsPartOfTheFrame() {
        var state = PipeTransferState()
        let attached = state.attach(identity: 7, token: 70)
        #expect(attached)
        guard let end = PipeFrame(count: 0, flags: PipeFrame.endFlag, token: 70) else {
            Issue.record("end")
            return
        }

        #expect(state.checked(end, identity: 7, token: 70, extent: 4096, destinationCapacity: 0) == .ok)
        #expect(state.ended)
        #expect(state.checked(end, identity: 7, token: 70, extent: 4096, destinationCapacity: 0) == .ended)
    }

    @Test("a different endpoint identity cannot advance the held transfer")
    func identityOwnsFrames() {
        var state = PipeTransferState()
        let attached = state.attach(identity: 7, token: 70)
        #expect(attached)
        guard let frame = PipeFrame(count: 4, flags: 0, token: 70) else {
            Issue.record("frame")
            return
        }

        #expect(state.checked(
            frame, identity: 9, token: 70, extent: 4096, destinationCapacity: 4096
        ) == .notOwner)
        #expect(!state.ended)
        #expect(state.checked(
            frame, identity: 7, token: 70, extent: 4096, destinationCapacity: 4096
        ) == .ok)
        #expect(!state.ended)
    }

    @Test("a different identity cannot replace the attached producer")
    func crossIdentityAttachIsRefused() {
        var state = PipeTransferState()
        let attached = state.attach(identity: 7, token: 70)
        #expect(attached)
        let replaced = state.attach(identity: 9, token: 90)
        #expect(!replaced)

        guard let frame = PipeFrame(count: 4, flags: 0, token: 70) else {
            Issue.record("frame")
            return
        }
        #expect(state.checked(
            frame, identity: 7, token: 70, extent: 4096, destinationCapacity: 4096
        ) == .ok)

        let refreshed = state.attach(identity: 7, token: 71)
        #expect(refreshed)
        #expect(state.checked(
            frame, identity: 7, token: 70, extent: 4096, destinationCapacity: 4096
        ) == .notOwner)
        guard let replacement = PipeFrame(count: 4, flags: 0, token: 71) else {
            Issue.record("replacement")
            return
        }
        #expect(state.checked(
            replacement, identity: 7, token: 71, extent: 4096, destinationCapacity: 4096
        ) == .ok)
    }

    @Test("acknowledgements bind to the producer session")
    func acknowledgementBindsSession() {
        guard let frame = PipeFrame(count: 4, flags: 0, token: 70) else {
            Issue.record("frame")
            return
        }
        #expect(PipeAcknowledgement(count: 4, status: .ok, flags: 0, token: 70).accepts(frame))
        #expect(!PipeAcknowledgement(count: 4, status: .ok, flags: 0, token: 71).accepts(frame))
        #expect(PipeFrame(count: 4, flags: 0, token: 0) == nil)
    }

    @Test("replacement preserves the old attachment until the new one is ready")
    func replacementIsAtomic() {
        var slot = ShmAttachment.Slot()
        guard let first = slot.nextEpoch() else {
            Issue.record("first epoch")
            return
        }
        #expect(slot.install(attachment(first, 10)) == nil)

        #expect(slot.current?.grant == 10)

        guard let second = slot.nextEpoch() else {
            Issue.record("second epoch")
            return
        }
        let released = slot.install(attachment(second, 11))
        #expect(released?.grant == 10)
        #expect(slot.current?.grant == 11)
        #expect(slot.take()?.grant == 11)
        #expect(slot.current == nil)
    }
}
