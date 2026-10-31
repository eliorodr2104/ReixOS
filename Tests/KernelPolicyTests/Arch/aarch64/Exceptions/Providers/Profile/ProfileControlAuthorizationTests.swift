//
//  ProfileControlAuthorizationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI

extension KernelPolicyTestRoot {
@Suite("ProfileControl authorization")
struct ProfileControlAuthorizationTests {
    @Test("authority and attach handles reject high bits")
    func handlesRejectHighBits() {
        let oversized = UInt64(UInt32.max) + 1
        #expect(ProfileABI.authorityHandle(oversized) == nil)
        #expect(ProfileABI.attachHandle(oversized) == nil)
        #expect(ProfileABI.authorityHandle(UInt64(UInt32.max)) == UInt32.max)
        #expect(ProfileABI.attachHandle(UInt64(UInt32.max)) == UInt32.max)
    }

    @Test("every operation is gated on its documented category")
    func categoryMatrix() {
        let counters: [ProfileOperation] = [
            .disable, .enable, .reset, .setSampleDivider, .pmuProbe,
        ]
        for operation in counters {
            #expect(ProfileABI.category(of: operation) == .profileCounters)
        }
        #expect(ProfileABI.category(of: .dumpConsole) == .profileConsole)
        #expect(ProfileABI.category(of: .attachExport) == .profileStats)
        #expect(ProfileABI.category(of: .interactionMark) == .profileMark)
    }

    @Test("missing handle is denied")
    func missingHandle() {
        let caps = CapsTable()
        #expect(!ProfileAuthorization.allows(caps, handle: 7, category: .profileCounters))
    }

    @Test("unrelated target is denied")
    func unrelatedTarget() {
        var caps = CapsTable()
        let handle = caps.install(Capability(
            target: .device(DeviceRegion(address: 0, size: 4096)),
            badge: 0,
            rights: [.profile]
        ))!
        #expect(!ProfileAuthorization.allows(caps, handle: handle, category: .profileCounters))
    }

    @Test("profile target without the matching category right is denied")
    func insufficientRights() {
        var caps = CapsTable()
        let handle = caps.install(Capability(
            target: .profileControl,
            badge: 0,
            rights: [.grant]
        ))!
        #expect(!ProfileAuthorization.allows(caps, handle: handle, category: .profileCounters))
    }

    @Test("profile target authorizes only the category its rights carry")
    func validAuthority() {
        let categories: [CapRights] = [.profileStats, .profileConsole, .profileCounters, .profileMark]

        for category in categories {
            var caps = CapsTable()
            let handle = caps.install(Capability(
                target: .profileControl,
                badge: 0,
                rights: category
            ))!

            #expect(ProfileAuthorization.allows(caps, handle: handle, category: category))
            for other in categories where other != category {
                #expect(!ProfileAuthorization.allows(caps, handle: handle, category: other))
            }
        }
    }

    @Test("interaction trace capacities match the build mode")
    func interactionTraceLayout() {
        #expect(TraceInteraction.bit == 1 << 8)
        #expect(MemoryLayout<TraceEvent>.size == 32)
        #expect(MemoryLayout<TraceEvent>.stride == 32)

        #if REIX_TERMINAL_PROFILE
        #expect(TraceInteraction.isEnabled)
        #expect(TraceRing.capacity == 1024)
        #expect(SerialTransmitQueue.capacity == 131_072)

        // Maximum-width records for the live ring, all write-once boot phases,
        // and every process slot still leave room for dump framing. This is a
        // capacity proof for the configured bound, not a promise for an
        // unbounded number of future side-table records.
        let recordBytes = (Int(TraceRing.capacity) + 12 + 32) * 122
        #expect(recordBytes + 256 <= SerialTransmitQueue.capacity)
        #else
        #expect(!TraceInteraction.isEnabled)
        #expect(TraceRing.capacity == 256)
        #expect(SerialTransmitQueue.capacity == 16_384)
        #endif
    }
}


}
