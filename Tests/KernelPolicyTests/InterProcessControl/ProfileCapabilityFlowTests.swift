//
//  ProfileCapabilityFlowTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
import Foundation
@testable import Kernel
import ReixABI
import KernelTestSupport

extension KernelPolicyTestRoot {
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

        let launcher = ProfileAuthorityGrant.markerLauncher(source: 12)
        #expect(launcher.targetSlot == BootCap.profileMarker.rawValue)
        #expect(launcher.rights == UInt32(CapRights([.profileMark, .profileConsole, .grant]).rawValue))

        let forwarded = RendezvousIPC.attenuatedRights(
            source   : CapRights(rawValue: UInt16(launcher.rights)),
            requested: CapRights(rawValue: UInt16(console.rights))
        )
        #expect(forwarded == [.profileMark, .profileConsole])
        #expect(!forwarded.contains(.grant))
    }

    @Test("marker authority crosses one rendezvous and cannot cross the next")
    func interactionMarkerDeliveryStopsAtWorkload() {
        withKernelTestGlobals {
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
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
            endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
            defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

            let launcher = makeProcess(pid: 1)
            let workload = makeProcess(pid: 2)
            let consumer = makeProcess(pid: 3)
            for process in [launcher, workload, consumer] { attachMetadata(to: process) }
            defer {
                for process in [launcher, workload, consumer] {
                    destroyMetadata(of: process)
                    destroyProcess(process)
                }
                Arch.CPU.setCurrentProcess(0)
            }

            let receiveWorkload = Capability(
                target: .endpoint(endpoint), badge: 0, rights: [.receive]
            )
            let sendLauncher = Capability(
                target: .endpoint(endpoint), badge: 0, rights: [.send]
            )
            let launcherMarker = Capability(
                target: .profileControl,
                badge : 0,
                rights: [.profileMark, .profileConsole, .grant]
            )
            _ = workload.pointee.metadata.pointee.capsTable.install(receiveWorkload)
            ipc.pointee.retain(receiveWorkload)
            _ = launcher.pointee.metadata.pointee.capsTable.install(sendLauncher)
            ipc.pointee.retain(sendLauncher)
            let launcherMarkerHandle = launcher.pointee.metadata.pointee.capsTable.install(
                launcherMarker
            )!
            ipc.pointee.retain(launcherMarker)

            let workloadFrame = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            workloadFrame.initialize(to: Arch.TrapFrame())
            defer { workloadFrame.deinitialize(count: 1); workloadFrame.deallocate() }
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: workload)))
            _ = ipc.pointee.receive(capability: receiveWorkload, frame: workloadFrame)
            workload.pointee.context = workloadFrame

            var firstDelivery = Arch.TrapFrame()
            firstDelivery.x2 = 0xA11CE
            firstDelivery.x6 = UInt64(launcherMarkerHandle) |
                (UInt64(CapRights([.profileMark, .profileConsole]).rawValue) << 32)
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: launcher)))
            let first = ipc.pointee.send(capability: sendLauncher, frame: firstDelivery)
            guard case .success(.sended(let firstRejected)) = first,
                  let workloadMarkerHandle = IPCDelivery.grant(of: workloadFrame.pointee.x7),
                  let workloadMarker = workload.pointee.metadata.pointee.capsTable.resolve(
                    workloadMarkerHandle
                  )
            else {
                Issue.record("launcher marker did not cross the rendezvous")
                return
            }
            #expect(!firstRejected)
            #expect(workloadFrame.pointee.x2 == 0xA11CE)
            #expect(workloadMarker.target == .profileControl)
            #expect(workloadMarker.rights == [.profileMark, .profileConsole])
            #expect(!workloadMarker.rights.contains(.grant))

            let receiveConsumer = Capability(
                target: .endpoint(endpoint), badge: 0, rights: [.receive]
            )
            let sendWorkload = Capability(
                target: .endpoint(endpoint), badge: 0, rights: [.send]
            )
            _ = consumer.pointee.metadata.pointee.capsTable.install(receiveConsumer)
            ipc.pointee.retain(receiveConsumer)
            _ = workload.pointee.metadata.pointee.capsTable.install(sendWorkload)
            ipc.pointee.retain(sendWorkload)

            let consumerFrame = UnsafeMutablePointer<Arch.TrapFrame>.allocate(capacity: 1)
            consumerFrame.initialize(to: Arch.TrapFrame())
            defer { consumerFrame.deinitialize(count: 1); consumerFrame.deallocate() }
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: consumer)))
            _ = ipc.pointee.receive(capability: receiveConsumer, frame: consumerFrame)
            consumer.pointee.context = consumerFrame

            var secondDelivery = Arch.TrapFrame()
            secondDelivery.x2 = 0xC105ED
            secondDelivery.x6 = UInt64(workloadMarkerHandle) |
                (UInt64(CapRights.profileMark.rawValue) << 32)
            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: workload)))
            let second = ipc.pointee.send(capability: sendWorkload, frame: secondDelivery)
            guard case .success(.sended(let secondRejected)) = second else {
                Issue.record("the message carrying the refused grant was not delivered")
                return
            }
            #expect(secondRejected)
            #expect(consumerFrame.pointee.x2 == 0xC105ED)
            #expect(IPCDelivery.grant(of: consumerFrame.pointee.x7) == nil)
            #expect(consumer.pointee.metadata.pointee.capsTable.findFirst(for: .profileMark) == nil)
        }
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
        #expect(source.contains("ProfileAuthorityGrant.markerLauncher(source: profiler)"))
        #expect(!source.contains("ProfileAuthorityGrant.marker(source: profiler, console: true)"))
        #expect(source.components(separatedBy: "ProfileAuthorityGrant.marker(").count == 2)
        #expect(source.components(separatedBy: "ProfileAuthorityGrant.markerLauncher(").count == 2)
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
        #expect(syscall.contains("static let maximumGrantCount = 10"))
        #expect(syscall.contains("frame.pointee.x3 <= UInt64(maximumGrantCount)"))
    }

}


}
