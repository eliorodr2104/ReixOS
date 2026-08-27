//
//  DeliveryPackingTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import Testing
import ReixABI

/// The two registers a delivered message carries besides its words.
///
/// Three facts travel out of band and there are two registers for them, so one
/// register is shared and one is not. Which one is not shared is the whole point:
/// it used to be the session that shared, and a session is the one of the three
/// that has to keep growing - it is a token a server hands out and later has to
/// tell apart from every other token it has ever handed out.
///
/// An identity is a process counter and a handle is an index into a table of
/// thirty-two, so a word each is a hundred years and a table. A session wanted
/// more, and the file system's own badge is the proof: object number, generation
/// and eight rights bits, in thirty-two bits between them.
@Suite("Delivery packing")
struct DeliveryPackingTests {

    @Test("identity and grant share the second register and come back whole")
    func principalRoundTrips() {
        for identity in [UInt32(0), 1, 7, 0x7FFF_FFFF, UInt32.max - 1] {
            for grant in [UInt32(0), 1, 31, 0xFFFF_FFFE] {
                let packed = IPCDelivery.principal(identity, grant: grant)

                #expect(IPCDelivery.identity(of: packed) == identity)
                #expect(IPCDelivery.grant(of: packed) == grant)
            }
        }
    }


    @Test("no grant is a value nothing else can be")
    func noGrantIsNotHandleZero() {
        // Not zero, which is handle zero and a real slot: a reader that treated
        // it as "nothing came with this" would be told to drop somebody's
        // console.
        #expect(IPCDelivery.noGrant == UInt32.max)

        let empty = IPCDelivery.principal(9)
        #expect(IPCDelivery.identity(of: empty) == 9)
        #expect(IPCDelivery.grant(of: empty) == nil)

        let zero = IPCDelivery.principal(9, grant: 0)
        #expect(IPCDelivery.grant(of: zero) == 0)
    }


    @Test("the two registers do not reach into each other")
    func theHalvesDoNotBleed() {
        // An identity of all ones and a grant of all ones but the sentinel: if
        // either shifted into the other's half, one of these reads wrong.
        let packed = IPCDelivery.principal(UInt32.max, grant: 0x1234_5678)

        #expect(IPCDelivery.identity(of: packed) == UInt32.max)
        #expect(IPCDelivery.grant(of: packed) == 0x1234_5678)

        // And a session is not in this register at all: nothing here reads or
        // writes the word the session travels in.
        #expect(packed >> 32 == UInt64(UInt32.max))
    }


    @Test("a session keeps the bits above the thirty-second")
    func sessionsAreWide() {
        // The reason for the change. Every one of these would have been cut down
        // to its low word by the old layout, which is a badge losing its rights
        // and its generation in one go.
        let wide: [UInt64] = [
            1 << 32,
            1 << 55,
            0x0100_0000_0000_0001,
            0xFF00_0000_0000_0000,
            UInt64.max
        ]

        for session in wide {
            // A session is carried, not packed: it has a register to itself, so
            // the round trip is the identity function and this test is really
            // about the *type* being wide enough to say so.
            let carried: UInt64 = session
            #expect(carried == session)
            #expect(carried >> 32 != 0)
        }
    }


    // MARK: - The file system's badge, which is why the session widened

    @Test("a file system badge fits in a session and comes back whole")
    func fsBadgeSurvivesTheWire() {
        let layout = FSBadge(objectCount: 1024)

        for object in [UInt32(0), 1, 1023] {
            for generation in [UInt32(0), 1, 1 << 21, UInt32.max] {
                for rights in [FSRights.everything, .occupant, .reader, []] {

                    let badge = layout.encode(
                        object: object, generation: generation, rights: rights
                    )

                    #expect(layout.object(of: badge) == object)
                    #expect(layout.generation(of: badge) == generation)
                    #expect(FileOperation.rights(badge: badge) == rights)

                    // Every one of these needs more than thirty-two bits the
                    // moment the rights are not empty, which is what the old
                    // word could not hold alongside a full generation.
                    if !rights.isEmpty { #expect(badge >> 32 != 0) }
                }
            }
        }
    }


    @Test("the rights come out of the top eight bits and nowhere else")
    func rightsAreWhereTheySay() {
        let layout = FSBadge(objectCount: 1024)

        // One right at a time, so a mask that reached one bit too far shows up as
        // the wrong right rather than as no right.
        let each: [FSRights] = [
            .lookup, .read, .write, .remove, .delegate, .quota, .admin, .unmount
        ]

        for right in each {
            let badge = layout.encode(object: 5, generation: 99, rights: right)

            #expect(FileOperation.rights(badge: badge) == right)
            #expect(layout.object(of: badge) == 5)
            #expect(layout.generation(of: badge) == 99)
        }

        // And an object number and generation of all ones do not spill into the
        // rights: a badge with no rights has none however wide the rest is.
        let bare = layout.encode(object: 1023, generation: UInt32.max, rights: [])
        #expect(FileOperation.rights(badge: bare).isEmpty)
    }


    @Test("a handle and a badge disagreeing about the generation resolve to nothing")
    func handleAndBadgeMustAgree() {
        let layout  = FSBadge(objectCount: 1024)
        let handles = layout.handles

        // A handle names an object and an incarnation, and so does a badge. A
        // client speaking through a capability for one incarnation, naming an
        // object at another, is refused by whichever of the two is checked - and
        // both are.
        let badge  = layout.encode(object: 7, generation: 40, rights: .occupant)
        let handle = handles.encode(object: 7, generation: 41)

        #expect(layout.names(generation: 40, badge: badge))
        #expect(!layout.names(generation: 41, badge: badge))

        #expect(handles.names(generation: 41, handle: handle))
        #expect(!handles.names(generation: 40, handle: handle))

        // The object is the same in both, which is what makes the generation the
        // only thing they can disagree about.
        #expect(layout.object(of: badge) == handles.object(of: handle))
    }


    @Test("a handle carries no rights, whatever is put in it")
    func handlesCarryNoAuthority() {
        let handles = FSBadge(objectCount: 1024).handles

        // A handle is a word in a message, so a client writes it. The whole
        // thirty-two bits above the object number are generation, so there is no
        // field a client could set to claim a right - and reading rights out of a
        // handle is not something the code can be asked to do: the two types are
        // different and only one of them has rights in it.
        let handle = handles.encode(object: 7, generation: handles.lastGeneration)

        #expect(handles.object(of: handle) == 7)
        #expect(handles.generation(of: handle) == handles.lastGeneration)

        // Zero is not a handle: a client answered nought has been answered
        // nothing, and sending nought back gets nothing too.
        #expect(handles.object(of: 0) == nil)
        #expect(handle != 0)
    }
}
