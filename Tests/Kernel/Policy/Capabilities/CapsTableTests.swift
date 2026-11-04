//
//  CapsTableTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/11/2026.


import Testing
@testable import Kernel
import ReixABI

/// Capability readers must keep their answers when the table is read in place.
///
/// The first and last slots, stale handles and the lowest matching right pin
/// the lookup contract while the linked-image check guards against copies.
extension KernelPolicyTestRoot {
@Suite("Capability table readers")
struct CapsTableTests {

    private func capability(_ badge: Badge, rights: CapRights = [.send]) -> Capability {
        Capability(target: .profileControl, badge: badge, rights: rights)
    }

    @Test("resolve reads the first and last slots and leaves an empty slot empty")
    func resolveAnswersTheFirstAndLastSlot() {
        var caps = CapsTable()
        let first = capability(11)
        let last  = capability(22)
        #expect(caps.install(at: 0, first).installed)
        #expect(caps.install(at: 31, last).installed)
        #expect(caps.resolve(0) == first)
        #expect(caps.resolve(31) == last)
        #expect(caps.resolve(15) == nil)
    }

    @Test("resolve refuses every handle beyond the table")
    func resolveRefusesEveryHandlePastTheTable() {
        var caps = CapsTable()
        for slot in 0..<CapsTable.slotCount {
            #expect(caps.install(at: slot, capability(Badge(slot) + 1)).installed)
        }
        #expect(caps.resolve(32) == nil)
        #expect(caps.resolve(33) == nil)
        #expect(caps.resolve(UInt32.max) == nil)
    }

    @Test("resolve follows removal and reinstall at the same slot")
    func resolveFollowsRemovalAndReinstall() {
        var caps = CapsTable()
        let first = capability(11)
        let next  = capability(22)
        #expect(caps.install(at: 5, first).installed)
        #expect(caps.remove(handle: 5) == first)
        #expect(caps.resolve(5) == nil)
        #expect(caps.install(at: 5, next).installed)
        #expect(caps.resolve(5) == next)
    }

    @Test("findFirst returns the lowest slot with the requested right")
    func findFirstNamesTheLowestSlotWithTheRight() {
        var caps = CapsTable()
        #expect(caps.install(at: 3, capability(11, rights: [.spawn])).installed)
        #expect(caps.install(at: 7, capability(22, rights: [.spawn])).installed)
        #expect(caps.findFirst(for: .spawn) == 3)
    }

    @Test("findFirst skips empty slots and capabilities with other rights")
    func findFirstSkipsEmptySlotsAndOtherRights() {
        var caps = CapsTable()
        #expect(caps.install(at: 1, capability(11)).installed)
        #expect(caps.install(at: 2, capability(22, rights: [.spawn, .send])).installed)
        #expect(caps.findFirst(for: .spawn) == 2)
        #expect(caps.findFirst(for: .receive) == nil)
    }

    @Test("findFirst reaches the last slot")
    func findFirstReachesTheLastSlot() {
        var caps = CapsTable()
        #expect(caps.install(at: 31, capability(11, rights: [.spawn])).installed)
        #expect(caps.findFirst(for: .spawn) == 31)
    }
}
}
