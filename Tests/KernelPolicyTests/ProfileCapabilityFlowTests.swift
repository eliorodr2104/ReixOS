//
//  ProfileCapabilityFlowTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
import Foundation
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

        #expect(!Kernel.installProfilerCap(into: &caps))
        #expect(caps.resolve(BootCap.profiler.rawValue) == original)
    }

    @Test("Init owns profile authorities while Top receives only profileStats")
    func bootAndToolRights() {
        var caps = CapsTable()
        #expect(Kernel.installProfilerCap(into: &caps))

        let initial = caps.resolve(BootCap.profiler.rawValue)!
        #expect(initial.rights == [.grant, .profile, .profileMark])

        let tool = ProfileAuthorityGrant.tool(source: BootCap.profiler.rawValue)
        #expect(tool.targetSlot == 6)

        // `ProfileAuthorityGrant.tool` seeds a reader's share only: profileStats,
        // not the console dump or the PMU counters (see its doc comment).
        #expect(tool.rights == UInt32(CapRights.profileStats.rawValue))
    }

    @Test("interaction marks have their own authority bit and boot slot")
    func interactionMarkLayout() {
        #expect(CapRights.profileMark.rawValue == 1 << 9)
        #expect(CapRights.profileMark.rawValue != CapRights.profile.rawValue)
        #expect(BootCap.profileMarker.rawValue == 15)
        #expect(BootCap.profileMarker.rawValue != BootCap.profiler.rawValue)
    }

    @Test("interaction mark grants are exact and non-delegable")
    func interactionMarkGrant() {
        let plain = ProfileAuthorityGrant.marker(source: 12, console: false)
        #expect(plain.targetSlot == BootCap.profileMarker.rawValue)
        #expect(plain.rights == UInt32(CapRights.profileMark.rawValue))
        let console = ProfileAuthorityGrant.marker(source: 12, console: true)
        #expect(console.rights == UInt32(CapRights([.profileMark, .profileConsole]).rawValue))
        #expect(console.rights & UInt32(CapRights.grant.rawValue) == 0)
    }

    @Test("interaction trace packing fails closed")
    func interactionTraceMarkPacking() {
        for point in [
            InteractionTracePoint.serialDelivered,
            .inputDecoded,
            .shellConsumed,
            .editorCompleted,
            .parserCompleted,
            .presentationRequested,
            .consoleAcknowledged,
            .presentationFullBytes,
            .presentationDiffBytes,
            .presentationPlan,
        ] {
            let mark = InteractionTraceMark(point: point, correlation: 1, value: InteractionTraceMark.maxValue)!
            #expect(InteractionTraceMark(packed: mark.packed) == mark)
        }
        #expect(InteractionTraceMark(point: .inputDecoded, correlation: 0, value: 0) == nil)
        #expect(InteractionTraceMark(point: .inputDecoded, correlation: 1, value: InteractionTraceMark.maxValue + 1) == nil)
        #expect(InteractionTraceMark(packed: 0) == nil)
        #expect(InteractionTraceMark(packed: UInt64(11) << 32 | 1) == nil)
    }

    @Test("Init keeps profile interaction authority inside its compile-time branch")
    func initProfileInteractionGrantPolicy() throws {
        let root   = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Userland/Init/Init.swift"))
        for expected in ["arg: 0xFF", "arg: 0x1FF", "arg: 0x3F", "arg: 0x100"] { #expect(source.contains(expected)) }
        #expect(!source.contains("arg: 0x13F"))
        let afterDump       = try #require(source.components(separatedBy: "profileDump(authority: profiler)").dropFirst().first)
        let profileBranch   = try #require(afterDump.components(separatedBy: "#if REIX_TERMINAL_PROFILE").dropFirst().first?.components(separatedBy: "#else").first)
        let normalBranch    = try #require(afterDump.components(separatedBy: "#else").dropFirst().first?.components(separatedBy: "#endif").first)
        let reset           = try #require(profileBranch.range(of: "profileControl(.reset, authority: profiler)"))
        let interactionOnly = try #require(profileBranch.range(of: "profileControl(.enable, authority: profiler, arg: 0x100)"))
        #expect(reset.lowerBound < interactionOnly.lowerBound)
        #expect(!normalBranch.contains("profileControl(.reset"))
        #expect(source.components(separatedBy: "capacity: {").count == 3)
        for expected in ["ShellGrantCapacity.normal", "ShellGrantCapacity.terminalProfile"] {
            #expect(source.contains(expected))
        }
        let terminal = try #require(source.components(separatedBy: "let terminal =").dropFirst().first?.components(separatedBy: "guard let terminalEndpoint").first)
        #expect(terminal.contains("ProfileAuthorityGrant.marker(source: profiler, console: false)"))
        #expect(!terminal.contains("console: true"))
        #expect(source.contains("ProfileAuthorityGrant.marker(source: profiler, console: true)"))
        #expect(source.components(separatedBy: "ProfileAuthorityGrant.marker(").count == 3)
    }

    @Test("Init reserves every possible Shell capability grant")
    func initShellGrantCapacityPolicy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Userland/Init/Init.swift"), encoding: .utf8)
        let capacitySource = try String(
            contentsOf: root.appending(path: "Sources/Userland/Init/ShellGrantCapacity.swift"),
            encoding: .utf8
        )
        #expect(capacitySource.contains("static let normal          = 9"))
        #expect(capacitySource.contains("static let terminalProfile = 10"))
        #expect(source.contains("source: inputConsumer"))
        #expect(source.contains("precondition(count < grants.count)"))
        let syscall = try String(
            contentsOf: root.appending(
                path: "Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXTask/SpawnProcessSyscall.swift"
            ),
            encoding: .utf8
        )
        #expect(syscall.contains("InlineArray<10, CapGrant>"))
        #expect(syscall.contains("frame.pointee.x3 <= 10"))
    }

}
