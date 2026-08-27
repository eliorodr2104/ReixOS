//
//  CapsTableCloneTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// `RendezvousIPC.cloneCapsTable`, the step that hands a forked child its
/// parent's authority.
///
/// It had no test of any kind, on any path: nothing in userland calls the
/// `split` syscall, so neither the host suites nor the boot matrix ever reached
/// it. In a capability kernel that is the wrong function to leave unobserved,
/// because both of the ways it can be wrong are silent. Copy too little and a
/// child loses a right it should have inherited; copy without retaining and the
/// target is freed under two live holders, which surfaces later and elsewhere
/// as a use-after-free.
///
/// The three collaborators `KernelIPC` stores are zeroed storage: the clone
/// reads the two metadata blocks and bumps reference counts through the
/// capability targets, and touches no allocator, scheduler or endpoint table on
/// the way. What it does touch is real.
@Suite("Caps table cloning")
struct CapsTableCloneTests {

    private func withForkFixture(
        endpoints count: Int,
        _ body         : (
            UnsafeMutablePointer<KernelIPC>,
            UnsafeMutablePointer<ProcessMetadata>,
            UnsafeMutablePointer<ProcessMetadata>,
            [UnsafeMutablePointer<Endpoint>]
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

        let parent = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
        let child  = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
        parent.initialize(to: ProcessMetadata())
        child .initialize(to: ProcessMetadata())
        defer {
            parent.deinitialize(count: 1); parent.deallocate()
            child .deinitialize(count: 1); child .deallocate()
        }

        let endpoints = (0..<count).map { _ -> UnsafeMutablePointer<Endpoint> in
            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            return endpoint
        }
        defer {
            for endpoint in endpoints {
                endpoint.deinitialize(count: 1)
                endpoint.deallocate()
            }
        }

        body(ipc, parent, child, endpoints)
    }

    private func capability(
        to endpoint: UnsafeMutablePointer<Endpoint>,
        badge      : UInt32,
        rights     : CapRights
    ) -> Capability {
        Capability(target: .endpoint(endpoint), badge: Badge(badge), rights: rights)
    }


    @Test("the child inherits every capability, at the slot the parent held it in")
    func inheritsSlots() {
        withForkFixture(endpoints: 3) { ipc, parent, child, endpoints in
            var slots: [UInt32] = []
            let rights: [CapRights] = [[.send], [.send, .receive], [.grant, .read, .write]]

            for (index, endpoint) in endpoints.enumerated() {
                let cap = capability(
                    to: endpoint, badge: UInt32(index + 1), rights: rights[index]
                )
                slots.append(parent.pointee.capsTable.install(cap)!)
            }

            ipc.pointee.cloneCapsTable(from: parent, to: child)

            for (index, slot) in slots.enumerated() {
                let inherited = child.pointee.capsTable.resolve(slot)

                #expect(inherited != nil)
                #expect(inherited == parent.pointee.capsTable.resolve(slot))

                // Rights are the whole point: a child that inherits a slot but
                // not its rights is a silently attenuated fork.
                #expect(inherited?.rights == rights[index])
                #expect(inherited?.badge  == Badge(UInt32(index + 1)))
            }
        }
    }


    @Test("every cloned capability retains its target exactly once")
    func retainsTargetsOnce() {
        withForkFixture(endpoints: 3) { ipc, parent, child, endpoints in
            // Two of the three endpoints go into the table; the third is the
            // control, and must come out of the clone untouched.
            for (index, endpoint) in endpoints.prefix(2).enumerated() {
                _ = parent.pointee.capsTable.install(
                    capability(to: endpoint, badge: UInt32(index + 1), rights: [.send])
                )
            }

            let before = endpoints.map { $0.pointee.references }
            #expect(before == [0, 0, 0])

            ipc.pointee.cloneCapsTable(from: parent, to: child)

            #expect(endpoints[0].pointee.references == 1)
            #expect(endpoints[1].pointee.references == 1)
            #expect(endpoints[2].pointee.references == 0)
        }
    }


    @Test("the same target held through two slots is retained once per slot")
    func retainsPerSlotNotPerTarget() {
        withForkFixture(endpoints: 1) { ipc, parent, child, endpoints in
            let endpoint = endpoints[0]

            // One endpoint, two capabilities on it with different rights: the
            // child inherits two holders of it, so it owes two references.
            _ = parent.pointee.capsTable.install(
                capability(to: endpoint, badge: 1, rights: [.send])
            )
            _ = parent.pointee.capsTable.install(
                capability(to: endpoint, badge: 2, rights: [.receive])
            )

            ipc.pointee.cloneCapsTable(from: parent, to: child)

            #expect(endpoint.pointee.references == 2)
        }
    }


    @Test("the two tables are independent afterwards")
    func tablesAreIndependent() {
        withForkFixture(endpoints: 3) { ipc, parent, child, endpoints in
            let shared = capability(to: endpoints[0], badge: 1, rights: [.send])
            let slot   = parent.pointee.capsTable.install(shared)!

            ipc.pointee.cloneCapsTable(from: parent, to: child)

            // The child gaining a capability must not give the parent one.
            let childOnly = capability(to: endpoints[1], badge: 2, rights: [.send])
            let childSlot = child.pointee.capsTable.install(childOnly)!
            #expect(parent.pointee.capsTable.resolve(childSlot) == nil)

            // And the parent dropping one must not disarm the child, which is
            // the direction that would matter on a real exit: the parent dies
            // first and the child keeps running on what it inherited.
            let removed = parent.pointee.capsTable.remove(shared)
            #expect(removed)
            #expect(parent.pointee.capsTable.resolve(slot) == nil)
            #expect(child .pointee.capsTable.resolve(slot) == shared)
        }
    }


    @Test("an empty parent table clones to an empty child and retains nothing")
    func emptyParent() {
        withForkFixture(endpoints: 1) { ipc, parent, child, endpoints in
            ipc.pointee.cloneCapsTable(from: parent, to: child)

            for slot in 0..<16 {
                #expect(child.pointee.capsTable.resolve(UInt32(slot)) == nil)
            }
            #expect(endpoints[0].pointee.references == 0)
        }
    }


    @Test("a full parent table clones every slot")
    func fullParent() {
        withForkFixture(endpoints: 1) { ipc, parent, child, endpoints in
            let endpoint = endpoints[0]

            // However wide the table is. Writing the number here twice is how
            // this test stopped being about a full table the day the table grew.
            let slots = parent.pointee.capsTable.caps.count

            for badge in 0..<slots {
                let installed = parent.pointee.capsTable.install(
                    capability(to: endpoint, badge: UInt32(badge), rights: [.send])
                )
                #expect(installed != nil)
            }
            #expect(!parent.pointee.capsTable.hasFreeSlot())

            ipc.pointee.cloneCapsTable(from: parent, to: child)

            #expect(!child.pointee.capsTable.hasFreeSlot())
            for slot in 0..<slots {
                #expect(child.pointee.capsTable.resolve(UInt32(slot)) != nil)
            }
            #expect(endpoint.pointee.references == UInt32(slots))
        }
    }
}
