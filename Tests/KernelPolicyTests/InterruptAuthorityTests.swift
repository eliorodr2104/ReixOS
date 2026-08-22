//
//  InterruptAuthorityTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// The interrupt keystone's bookkeeping: which lines a holder covers, which
/// holder owns a line, and what a handle is allowed to resolve to.
///
/// The masking itself is not here and cannot be: `GICv2.init` adds the
/// high-half offset to the register bases unconditionally, so the driver cannot
/// be built over host memory. What is covered is everything that decides *who*
/// gets an interrupt, which is the half that carries authority.
@Suite("Interrupt authority", .serialized)
struct InterruptAuthorityTests {

    private func withSet(_ body: (UnsafeMutablePointer<InterruptSet>) -> Void) {
        let set = UnsafeMutablePointer<InterruptSet>.allocate(capacity: 1)
        set.initialize(to: InterruptSet())
        defer {
            InterruptClaims.releaseAll(of: set)
            set.deinitialize(count: 1)
            set.deallocate()
        }

        body(set)
    }


    @Test("lines are given bits in the order they were added")
    func bitsFollowInsertion() {
        withSet { set in
            #expect(set.pointee.add(line: 33) == 0b001)
            #expect(set.pointee.add(line: 47) == 0b010)
            #expect(set.pointee.add(line: 12) == 0b100)

            #expect(set.pointee.lineCount == 3)
            #expect(set.pointee.bit(of: 33) == 0b001)
            #expect(set.pointee.bit(of: 47) == 0b010)
            #expect(set.pointee.bit(of: 12) == 0b100)

            // A line nobody added has no bit, which is what makes an interrupt
            // for another holder unroutable through this set.
            #expect(set.pointee.bit(of: 99) == nil)
        }
    }


    @Test("a set refuses a duplicate line and refuses to grow past its bits")
    func setBounds() {
        withSet { set in
            #expect(set.pointee.add(line: 33) != nil)
            #expect(set.pointee.add(line: 33) == nil)
            #expect(set.pointee.lineCount == 1)

            for line in 100..<107 {
                #expect(set.pointee.add(line: UInt32(line)) != nil)
            }

            // Eight lines, eight bits, and the ninth is refused rather than
            // silently landing on a bit that already means something else.
            #expect(set.pointee.lineCount == 8)
            #expect(set.pointee.add(line: 200) == nil)
            #expect(set.pointee.lineCount == 8)
        }
    }


    @Test("a line has one owner, and a second claim on it is refused")
    func oneOwnerPerLine() {
        withSet { first in
            withSet { second in
                #expect(InterruptClaims.claim(line: 33, by: first))
                #expect(InterruptClaims.owner(of: 33) == first)

                // The property the whole capability rests on: nobody takes a
                // device's line out from under the driver that holds it.
                #expect(!InterruptClaims.claim(line: 33, by: second))
                #expect(InterruptClaims.owner(of: 33) == first)
            }
        }
    }


    @Test("interrupt id zero is a line like any other, not an empty slot")
    func zeroIsALine() {
        withSet { set in
            #expect(InterruptClaims.claim(line: 0, by: set))

            // Occupancy is the owner pointer, never the line number: zero is the
            // first software generated interrupt, so reading it as "free slot"
            // would hand line 0 to two holders at once.
            #expect(InterruptClaims.owner(of: 0) == set)
            #expect(!InterruptClaims.claim(line: 0, by: set))
        }
    }


    @Test("releasing a holder frees its lines and leaves the others alone")
    func releaseIsScoped() {
        withSet { keeper in
            withSet { leaver in
                #expect(InterruptClaims.claim(line: 40, by: keeper))
                #expect(InterruptClaims.claim(line: 41, by: leaver))
                #expect(InterruptClaims.claim(line: 42, by: leaver))

                InterruptClaims.releaseAll(of: leaver)

                #expect(InterruptClaims.owner(of: 41) == nil)
                #expect(InterruptClaims.owner(of: 42) == nil)
                #expect(InterruptClaims.owner(of: 40) == keeper)

                // And a freed line can be taken again, which is what makes a
                // crashed driver's device usable by its replacement.
                #expect(InterruptClaims.claim(line: 41, by: keeper))
            }
        }
    }


    @Test("the claims table refuses to overflow")
    func claimsCapacity() {
        withSet { set in
            for line in 300..<(300 + UInt32(InterruptClaims.capacity)) {
                #expect(InterruptClaims.claim(line: line, by: set))
            }

            #expect(!InterruptClaims.claim(line: 999, by: set))
            #expect(InterruptClaims.owner(of: 999) == nil)
        }
    }


    // MARK: - Handle resolution

    private func withHolder(
        _ body: (UnsafeMutablePointer<Process>, UnsafeMutablePointer<ProcessMetadata>) -> Void
    ) {
        let metadata = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
        metadata.initialize(to: ProcessMetadata())
        defer { metadata.deinitialize(count: 1); metadata.deallocate() }

        let process = makeProcess(pid: 7)
        defer { destroyProcess(process) }
        process.pointee.metadata = metadata

        body(process, metadata)
    }


    @Test("a handle resolves to the set it names")
    func resolvesInterruptHandle() {
        withSet { set in
            withHolder { process, metadata in
                let slot = metadata.pointee.capsTable.install(
                    Capability(target: .interrupt(set), badge: Badge(0), rights: [.grant])
                )

                #expect(slot != nil)
                #expect(InterruptAuthority.resolve(handle: UInt64(slot!), of: process) == set)
            }
        }
    }


    @Test("a handle that names something else is refused")
    func refusesWrongTarget() {
        withHolder { process, metadata in
            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            let slot = metadata.pointee.capsTable.install(
                Capability(target: .endpoint(endpoint), badge: Badge(0), rights: [.send])
            )
            #expect(slot != nil)

            // An endpoint handle passed to `irqWait` must not be read as a set:
            // the two words behind a capability are the same size, and reading
            // an endpoint as an interrupt set would be a type confusion the
            // caller chooses.
            #expect(InterruptAuthority.resolve(handle: UInt64(slot!), of: process) == nil)
        }
    }


    @Test("an empty slot, an out-of-range handle and a process with no metadata are refused")
    func refusesNonHandles() {
        withHolder { process, _ in
            #expect(InterruptAuthority.resolve(handle: 0, of: process) == nil)
            #expect(InterruptAuthority.resolve(handle: 15, of: process) == nil)
            #expect(InterruptAuthority.resolve(handle: UInt64(UInt32.max) + 1, of: process) == nil)
        }

        let orphan = makeProcess(pid: 8)
        defer { destroyProcess(orphan) }
        orphan.pointee.metadata = nil

        #expect(InterruptAuthority.resolve(handle: 0, of: orphan) == nil)
    }
}
