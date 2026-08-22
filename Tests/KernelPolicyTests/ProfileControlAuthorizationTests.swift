//
//  ProfileControlAuthorizationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI

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
        let categories: [CapRights] = [.profileStats, .profileConsole, .profileCounters]

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
}
