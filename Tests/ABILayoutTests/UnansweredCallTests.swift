//
//  UnansweredCallTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI

/// Keeping the transport's answer and the server's answer apart.
///
/// `call` used to throw away the word the kernel leaves in `x0` while the
/// assembly copied `x1` through `x7` into the reply buffer regardless, so a
/// failed exchange came back with the *request* in the reply's place - and `ok`
/// is zero in every status enum here, which makes the most likely reading of a
/// failure "success".
///
/// The first fix put a reserved word in the message and had one protocol status
/// claim its number. That worked and was the wrong shape: it made a transport
/// failure a value inside a protocol's own enum, and left every protocol written
/// afterwards owing a number to a layer it knows nothing about. So `call` returns
/// a `Result` instead, and what cannot be tested from a host - the syscall - is
/// at least no longer possible to get wrong silently: the message is unreachable
/// without saying what happens when there is none.
///
/// What is left to check here is the contract that makes the two channels
/// separate, and it is all arithmetic.
@Suite("Transport answers and protocol answers are not the same channel")
struct UnansweredCallTests {

    @Test("a delivered message is the only outcome that carries words")
    func onlyDeliveredCarriesAMessage() {
        // What `call` keys off. `grantRejected` is a *delivered* reply whose
        // capability did not travel, so its words are real and it must not be
        // thrown away with the failures.
        #expect(IPCStatus.ok.isDelivered)
        #expect(IPCStatus.grantRejected.isDelivered)

        for status in [IPCStatus.peerDied, .noReply, .timeout, .wouldBlock,
                       .notEnoughRights, .invalidCapability, .invalidMessage,
                       .outOfEndpoints] {
            #expect(!status.isDelivered)
        }
    }


    @Test("no protocol status is the transport's to set")
    func noProtocolStatusIsReserved() {
        // The property the first attempt gave up and this one keeps: nothing in
        // a protocol's status enum is spoken for by the layer underneath it. A
        // client that means "the exchange did not happen" says so itself.
        #expect(FSStatus.unreachable.rawValue != Message.unanswered.words[0])
        #expect(BlockStatus.unreachable.rawValue != Message.unanswered.words[0])

        // And neither of them is zero, which is the reading that mattered.
        #expect(FSStatus.unreachable.rawValue != 0)
        #expect(BlockStatus.unreachable.rawValue != 0)
        #expect(FSStatus.ok.rawValue == 0)
        #expect(BlockStatus.ok.rawValue == 0)
    }


    @Test("the filler for a receive that received nothing is not an operation")
    func fillerIsNotAnOperation() {
        // All that has to be true of it: every server loop reads the label first
        // and skips what it does not know.
        let label = Message.unanswered.tag.label

        #expect(BlockOperation(rawValue: label) == nil)
        #expect(FileOperation(rawValue: label) == nil)
    }


    @Test("the filler is not zero, because zero is what success looks like")
    func fillerIsNotZero() {
        for index in 0..<4 {
            #expect(Message.unanswered.words[index] != 0)
        }
    }


    @Test("a status a server really sent still reads as itself")
    func realAnswersAreUntouched() {
        // The separation must not swallow the ordinary answers, so each one goes
        // through the decoder it would take coming off the wire.
        for status in [FSStatus.ok, .notFound, .exists, .readOnly, .busy, .quarantined] {
            #expect(FileOperation.status(of: FileOperation.answer(status)) == status)
        }

        for status in [BlockStatus.ok, .outOfRange, .volumeHeld, .notAuthorised] {
            #expect(BlockOperation.status(of: BlockOperation.answer(status)) == status)
        }
    }


    @Test("replies carry the label of the request they answer")
    func repliesAreLabelled() {
        // What the shape check in each client rests on: a reply built with the
        // wrong constructor is not a plausible set of words, it is a different
        // label.
        #expect(FileOperation.answer(.ok).tag.label == FileOperation.status.rawValue)
        #expect(
            FileOperation.describing(.ok, object: 1, kind: .file, size: 0).tag.label
                == FileOperation.open.rawValue
        )
        #expect(
            BlockOperation.geometry(sectorSize: 512, sectorCount: 8, durability: .onFlush).tag.label
                == BlockOperation.geometry.rawValue
        )
    }


    @Test("a reply says how many of its words it filled in")
    func repliesSayTheirLength() {
        // The other half of the shape check. Reading past what the server wrote
        // is reading whatever was in the frame.
        #expect(FileOperation.answer(.ok).tag.length == 2)
        #expect(FileOperation.describing(.ok, object: 1, kind: .file, size: 0).tag.length == 4)
        #expect(FileOperation.standing(root: 1, free: 2, used: 3, dirty: false).tag.length == 4)
        #expect(BlockOperation.geometry(sectorSize: 512, sectorCount: 8, durability: .onFlush).tag.length == 4)
    }
}
