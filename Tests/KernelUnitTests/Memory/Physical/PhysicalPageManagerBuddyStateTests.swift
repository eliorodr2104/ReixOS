//
//  PhysicalPageManagerBuddyStateTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport

/// The manager over the real buddy, checked against the buddy's own free state:
/// what the manager counts as held and what the buddy holds free must partition
/// RAM after every call, and a refusal from the buddy must leave the manager's
/// metadata and accounting exactly where they were.
@Suite("Physical page manager over buddy block state")
struct PhysicalPageManagerBuddyStateTests {

    @Test("a final free the buddy refuses leaves metadata and accounting untouched")
    func buddyRefusalIsAtomic() throws {
        try withLiveManager(pages: 64) { ram in
            let first  = try ram.ppm.pointee.alloc(4096)
            let second = try ram.ppm.pointee.alloc(4096)
            #expect(second.address == first.address + 4096)

            // The buddy is told the frame is free behind the manager's back, so the
            // metadata still calls it held and only the buddy can refuse.
            try ram.buddy.free(PhysicalPage(address: first.address, order: 0))
            let before = ram.pmmStateSnapshot()

            #expect(refusal { try ram.ppm.pointee.free(PhysicalPage(address: first.address, order: 0)) } == "allocationFailed")
            #expect(ram.pmmStateSnapshot() == before)
            #expect(ram.ppm.pointee.allocatedPages == 2)
            #expect(ram.ppm.pointee.refCount(of: first.address) == 1)
        }
    }


    @Test("a seeded workload keeps the buddy's free state and the manager's count in step")
    func seededWorkload() throws {
        try withLiveManager(pages: 256) { ram in
            struct Held { let address: PhysicalAddress; let order: UInt8; let flag: PhysicalPageFlags; var refs: UInt32 }

            let flags: [PhysicalPageFlags] = [.none, .user, .kernel, .heapLarge, [.kernel, .heapLarge]]
            var rng  = SplitMix64(seed: 0x9E3_0B0D_D1E5)
            var held : [Held] = []

            for step in 0..<2000 {
                let choice = rng.below(100)

                if held.isEmpty || choice < 45 {
                    let flag = flags[rng.below(flags.count)]
                    let before = ram.pmmStateSnapshot()

                    do {
                        let page = try ram.ppm.pointee.alloc(4096 << rng.below(5), flag: flag)
                        held.append(Held(address: page.address, order: page.order, flag: flag, refs: 1))
                    } catch {
                        #expect(ram.pmmStateSnapshot() == before, "step \(step)")
                    }

                } else if choice < 60 {
                    let index = rng.below(held.count)
                    if held[index].refs < 3 {
                        try ram.ppm.pointee.retain(held[index].address)
                        held[index].refs += 1
                    }

                } else {
                    let index = rng.below(held.count)
                    let block = held[index]

                    if block.flag.contains(.kernel) {
                        try ram.ppm.pointee.freeOwnedKernelPage(PhysicalPage(address: block.address, order: block.order))
                    } else {
                        try ram.ppm.pointee.free(PhysicalPage(address: block.address, order: block.order))
                    }

                    held[index].refs -= 1
                    if held[index].refs == 0 { held.remove(at: index) }
                }

                let live       = held.map { ($0.address, $0.order) }
                let violations = buddyViolations(ram.buddy, freePages: Int(ram.ppm.pointee.freePages), live: live)
                #expect(violations.isEmpty, "step \(step): \(violations)")
                #expect(ram.ppm.pointee.allocatedPages == UInt64(live.reduce(0) { $0 + (1 << Int($1.1)) }))
                if !violations.isEmpty { return }
            }
        }
    }


    @Test("a reclaimed device tree merges with its neighbours into the whole-RAM shape")
    func reclaimCoalesces() {
        withHostRAM(pages: 600) { reference in
            reference.donateAll()
            let whole = shape(reference.buddy).map { $0.map { $0 - reference.base } }

            withHostRAM(pages: 600) { ram in
                let start = ram.page(100)
                let end   = ram.page(300)

                ram.markReserved(from: start, to: end)
                ram.donate(from: ram.base, to: start)
                ram.donate(from: end, to: ram.end)
                ram.installLiveManager(deviceTree: (start: start, end: end), reservePages: 0)

                #expect(buddyViolations(ram.buddy, freePages: 400).isEmpty)
                #expect((try? ram.ppm.pointee.reclaimDeviceTree()) == 200 * 4096)

                #expect(ram.ppm.pointee.allocatedPages == 0)
                #expect(buddyViolations(ram.buddy, freePages: 600).isEmpty)
                #expect(shape(ram.buddy).map { $0.map { $0 - ram.base } } == whole)
            }
        }
    }
}


private func withLiveManager(
    pages : Int,
    _ body: (HostRAM) throws -> Void
) throws {
    let ram = HostRAM(pages: pages)
    defer { ram.release() }

    #expect(ram.donateAll())
    ram.installLiveManager(reservePages: 0)

    try body(ram)
}
