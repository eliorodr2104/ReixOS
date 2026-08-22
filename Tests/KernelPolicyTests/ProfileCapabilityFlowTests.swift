//
//  ProfileCapabilityFlowTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI

@Suite("Profile capability flow")
struct ProfileCapabilityFlowTests {
    @Test("delegation cannot amplify profile right")
    func delegationPolicyCannotAmplify() {
        let source: CapRights = [.grant]
        let requested: CapRights = [.grant, .profile]

        #expect(!RendezvousIPC.attenuatedRights(source: source, requested: requested).contains(.profile))
    }

    @Test("mint cannot amplify profile and always removes derive")
    func mintCannotAmplify() {
        var caps = CapsTable()
        let source = caps.install(Capability(
            target: .profileControl,
            badge: 0,
            rights: [.grant, .derive]
        ))!

        let minted = caps.mint(
            from: source,
            session: 1,
            rights: [.grant, .derive, .profile]
        )!
        let rights = caps.resolve(minted)!.rights

        #expect(rights == [.grant])
        #expect(!rights.contains(.profile))
        #expect(!rights.contains(.derive))
    }

    @Test("profile right survives reduction only when source owns it")
    func profileRightCanBeReduced() {
        let source: CapRights = [.grant, .profile]
        let requested: CapRights = [.profile]

        #expect(RendezvousIPC.attenuatedRights(source: source, requested: requested) == [.profile])
    }

    @Test("boot profiler slot is distinct and collision is rejected")
    func bootSlotCollision() {
        #expect(BootCap.profiler.rawValue == 6)
        #expect(BootCap.profiler.rawValue != BootCap.device.rawValue)
        #expect(BootCap.profiler.rawValue != BootCap.nameServerRegistrar.rawValue)

        var caps = CapsTable()
        let original = Capability(
            target: .device(DeviceRegion(address: 0x1000, size: 0x1000)),
            badge: 0,
            rights: [.read]
        )
        let installed = caps.install(at: BootCap.profiler.rawValue, original)
        #expect(installed.installed)

        #expect(!ProfilerBootAuthority.install(into: &caps))
        #expect(caps.resolve(BootCap.profiler.rawValue) == original)
    }

    @Test("Init owns grant plus profile while Top receives only profileStats")
    func bootAndToolRights() {
        var caps = CapsTable()
        #expect(ProfilerBootAuthority.install(into: &caps))

        let initial = caps.resolve(BootCap.profiler.rawValue)!
        #expect(initial.rights == [.grant, .profile])

        let tool = ProfileAuthorityGrant.tool(source: BootCap.profiler.rawValue)
        #expect(tool.targetSlot == 6)

        // `ProfileAuthorityGrant.tool` seeds a reader's share only: profileStats,
        // not the console dump or the PMU counters (see its doc comment).
        #expect(tool.rights == UInt32(CapRights.profileStats.rawValue))
    }
}
