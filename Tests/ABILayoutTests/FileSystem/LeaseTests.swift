//
//  LeaseTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI

/// Claims, and the two holders it takes to see anything.
///
/// Every case that matters here needs two clients, which is why the table was
/// pulled out of the server to be looked at: one process cannot arrange for
/// somebody else to be holding what it wants, and the server is not a thing a
/// host test can build.
///
/// A claim is an *application* lock. It keeps one client's several requests from
/// having another client's single one land in the middle. It is not a
/// transaction and does not pretend to be: what survives a power cut is the
/// write order, and that is somewhere else entirely.
@Suite("Claims name a thing, not a slot")
struct LeaseTests {

    private static let alice: UInt32 = 11
    private static let bob  : UInt32 = 22


    @Test("what nobody claimed, anybody may change")
    func unclaimedIsOpen() {
        // The default, and it is the permissive one on purpose: a claim is
        // something a client asks for, not something imposed on everybody who
        // never asked.
        var leases = FSLeases()

        let answer = leases.mayChange(7, generation: 0, by: Self.alice)
        #expect(answer)
        let answer1 = leases.mayChange(7, generation: 0, by: Self.bob)
        #expect(answer1)
    }


    @Test("a claim keeps the other one out and lets its holder through")
    func claimIsExclusive() {
        var leases = FSLeases()

        let answer = leases.claim(7, generation: 3, for: Self.alice)
        #expect(answer)

        let answer1 = leases.mayChange(7, generation: 3, by: Self.alice)
        #expect(answer1)
        let answer2 = leases.mayChange(7, generation: 3, by: Self.bob)
        #expect(!answer2)

        // And asking again for what you already hold is yes, not busy.
        let answer3 = leases.claim(7, generation: 3, for: Self.alice)
        #expect(answer3)
        let answer4 = leases.claim(7, generation: 3, for: Self.bob)
        #expect(!answer4)
    }


    @Test("letting go is for the holder, and only the holder")
    func onlyTheHolderReleases() {
        var leases = FSLeases()

        let answer = leases.claim(7, generation: 3, for: Self.alice)
        #expect(answer)

        leases.release(7, from: Self.bob)
        let stillHeld = leases.mayChange(7, generation: 3, by: Self.bob)
        #expect(!stillHeld, "somebody else's claim was let go")

        leases.release(7, from: Self.alice)
        let answer1 = leases.mayChange(7, generation: 3, by: Self.bob)
        #expect(answer1)
    }


    // MARK: - The thing, not the slot

    @Test("a claim does not follow the slot to the next object in it")
    func claimDoesNotOutliveItsObject() {
        // The whole reason a claim carries a count. Alice claims object seven;
        // seven is removed and the slot handed to something of Bob's. Without
        // the count, Bob is locked out of his own new file by a claim on a file
        // that no longer exists - and nothing would ever let it go, because
        // Alice has nothing left to release.
        var leases = FSLeases()

        let answer = leases.claim(7, generation: 3, for: Self.alice)
        #expect(answer)

        // Same slot, next incarnation.
        let answer1 = leases.mayChange(7, generation: 4, by: Self.bob)
        #expect(answer1)
        let answer2 = leases.claim(7, generation: 4, for: Self.bob)
        #expect(answer2)

        // And now it is Bob's, properly.
        let answer3 = leases.mayChange(7, generation: 4, by: Self.alice)
        #expect(!answer3)
    }


    @Test("a claim on an object that is gone is not a claim")
    func claimOnAVanishedObjectIsForgotten() {
        var leases = FSLeases()

        let answer = leases.claim(7, generation: 3, for: Self.alice)
        #expect(answer)

        // No generation at all: there is nothing at that number now.
        let answer1 = leases.mayChange(7, generation: nil, by: Self.bob)
        #expect(answer1)
    }


    @Test("a stale claim gives its slot back rather than filling the table")
    func staleClaimsFreeTheirSlots() {
        var leases = FSLeases()

        // Fill it, all held by Alice.
        for object in 0..<UInt32(FSLeases.capacity) {
            let answer = leases.claim(object, generation: 1, for: Self.alice)
            #expect(answer)
        }

        // Full: nothing else fits.
        let answer1 = leases.claim(99, generation: 1, for: Self.bob)
        #expect(!answer1)

        // One of the objects moves on, which is noticed the next time anybody
        // asks about it - and that hands the slot back.
        let answer2 = leases.mayChange(3, generation: 2, by: Self.bob)
        #expect(answer2)
        let answer3 = leases.claim(99, generation: 1, for: Self.bob)
        #expect(answer3)
    }


    // MARK: - Going away

    @Test("a client that comes back is holding nothing")
    func reattachingLetsGoOfEverything() {
        // The one certain cleanup there is: attaching again is starting again.
        var leases = FSLeases()

        let answer = leases.claim(1, generation: 1, for: Self.alice)
        #expect(answer)
        let answer1 = leases.claim(2, generation: 1, for: Self.alice)
        #expect(answer1)
        let answer2 = leases.claim(3, generation: 1, for: Self.bob)
        #expect(answer2)

        leases.forget(everythingHeldBy: Self.alice)

        let answer3 = leases.mayChange(1, generation: 1, by: Self.bob)
        #expect(answer3)
        let answer4 = leases.mayChange(2, generation: 1, by: Self.bob)
        #expect(answer4)

        // And Bob's is untouched.
        let answer5 = leases.mayChange(3, generation: 1, by: Self.alice)
        #expect(!answer5)
    }


    // MARK: - Several objects at once

    @Test("asking about several objects gives the same answer in any order")
    func orderDoesNotMatter() {
        // Why there is no lock ordering here and none is wanted: a claim is a
        // refusal and never a wait, so nothing is held while asking for a
        // second, and there is no order to get wrong. Ordering starts to matter
        // the moment a claim blocks, and that is the moment to add it.
        var leases = FSLeases()

        let answer = leases.claim(5, generation: 1, for: Self.alice)
        #expect(answer)

        var forwards = FSLeases()
        var backward = FSLeases()
        let answer1 = forwards.claim(5, generation: 1, for: Self.alice)
        #expect(answer1)
        let answer2 = backward.claim(5, generation: 1, for: Self.alice)
        #expect(answer2)

        let first  = forwards.mayChange(4, generation: 1, by: Self.bob)
            && forwards.mayChange(5, generation: 1, by: Self.bob)

        let second = backward.mayChange(5, generation: 1, by: Self.bob)
            && backward.mayChange(4, generation: 1, by: Self.bob)

        #expect(first == second)
        #expect(!first)
    }

    /// A full table and a contested object are the same answer to a client and
    /// different facts about the server. Without a way to tell them apart, a
    /// fixed size of eight fails as though eight clients were arguing.
    @Test("a table with no room says so, separately from being contested")
    func saturationIsVisible() {
        var leases = FSLeases()

        #expect(!leases.isFull)
        #expect(leases.saturations == 0)

        for index in 0..<UInt32(FSLeases.capacity) {
            let taken = leases.claim(index, generation: 0, for: 1)
            #expect(taken)
        }

        #expect(leases.isFull)
        #expect(leases.saturations == 0)

        // One more, on an object nobody holds: refused for want of room.
        let overflowed = leases.claim(99, generation: 0, for: 1)
        #expect(!overflowed)
        #expect(leases.saturations == 1)

        // An object somebody else holds is refused too, and that is not
        // saturation: the table had nothing to do with it.
        let contested = leases.claim(0, generation: 0, for: 2)
        #expect(!contested)
        #expect(leases.saturations == 1)

        // Room again once something is let go of.
        leases.release(0, from: 1)
        #expect(!leases.isFull)

        let after = leases.claim(99, generation: 0, for: 1)
        #expect(after)
        #expect(leases.saturations == 1)
    }


    @Test("a slot number outside the table is refused at both ends")
    func slotNumbersAreBounded() {
        var leases = FSLeases()
        #expect(leases.claim(7, generation: 1, for: 9) == true)

        // Above the table, which was already refused.
        #expect(leases.entry(at: FSLeases.capacity) == nil)
        leases.forget(at: FSLeases.capacity)

        // And below it, which was not. A sweep walking this table with an index
        // it worked out from something else can arrive with a negative one, and a
        // negative subscript on a fixed array is not a wrong answer - it is the
        // server gone.
        #expect(leases.entry(at: -1) == nil)
        #expect(leases.entry(at: Int.min) == nil)

        leases.forget(at: -1)
        leases.forget(at: Int.min)

        // Nothing was disturbed by any of it.
        #expect(leases.entry(at: 0)?.object == 7)
    }
}
