//
//  RegistrarTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Testing
import ReixABI

/// A registrar badge is the whole of the Name Server's publishing rule: the
/// server reads which name a request may claim off the badge, so what these
/// asserts pin down is not an encoding but an authority.
@Suite("Name Server registrar")
struct RegistrarTests {

    /// The point of the badge. Minted for one name, it names that one.
    @Test("a badge names the service it was minted for")
    func namesItsService() {

        for raw in 0..<UInt32(Services.count) {
            let service = Services(rawValue: raw)
            #expect(service != nil)

            let badge = NameServerSession.registrar(for: service!)
            #expect(NameServerSession.service(of: badge) == service)
        }
    }

    /// Zero is what the kernel calls an unbadged capability, which is the one
    /// anybody may hold. A badge that came out zero would be a licence to
    /// publish handed to every process that can reach the Name Server.
    @Test("no badge is ever zero")
    func neverUnbadged() {

        for raw in 0..<UInt32(Services.count) {
            #expect(NameServerSession.registrar(for: Services(rawValue: raw)!) != 0)
        }
    }

    /// Lookup is unbadged, so this is the request the Name Server sees from
    /// every ordinary client: it may ask, it may not publish.
    @Test("an unbadged capability publishes nothing")
    func lookupOnly() {
        #expect(NameServerSession.service(of: 0) == nil)
    }

    /// What the hole looked like. `0x4E53_5247` was **the** registrar: one
    /// constant meaning "may register", shared by everyone who was given one, so
    /// any holder could publish any name. It has to name nothing now, or the
    /// capabilities minted under the old rule would still work under the new one.
    @Test("the old universal registrar names nothing")
    func oldConstantIsDead() {
        #expect(NameServerSession.service(of: 0x4E53_5247) == nil)
    }

    /// A word that is not a badge is not a badge, whichever half is wrong: the
    /// marker, or a service number past the end of the list.
    @Test("a word that is not a badge names nothing")
    func strangers() {
        #expect(NameServerSession.service(of: 0xDEAD_BEEF) == nil)
        #expect(NameServerSession.service(of: 0x4E53_0000) == nil)
        #expect(NameServerSession.service(
            of: 0x4E53_0000 | UInt64(Services.count) + 1
        ) == nil)

        // A word with anything above the marker in it is not one of these. The
        // session register is sixty-four bits now, so another protocol's badge
        // may well have the same low half.
        #expect(NameServerSession.service(of: 0x1_0000_4E53_0001) == nil)

        // The whole word is the badge, not its low half. A session word of one
        // belongs to some other protocol, and must not be a licence to publish
        // the first service in the list.
        #expect(NameServerSession.service(of: 1) == nil)
    }
}
