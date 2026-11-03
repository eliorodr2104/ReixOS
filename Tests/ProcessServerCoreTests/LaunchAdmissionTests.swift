//
//  LaunchAdmissionTests.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

@Suite("ProcessServer launch admission")
struct LaunchAdmissionTests {
    @Test func unavailableFilesReleaseReservation() {
        var host = FakeLaunchHost()
        host.filesAvailable = false
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.map { $0.1 } == [.unavailable])
        #expect(supervisor.isEmpty)
        #expect(host.shelves.values.allSatisfy { $0.claims == 0 })
        expectNothingHeld(host)
    }

    @Test func launchOfferBoundaries() {
        #expect(LaunchOffer.begin.acknowledgementIndex == UInt32.max)
        #expect(LaunchOffer.commit.acknowledgementIndex == UInt32.max)
        #expect(LaunchOffer.binding(0).acknowledgementIndex == 0)
        #expect(LaunchOffer.binding(15).acknowledgementIndex == 15)
        #expect(LaunchOffer.begin.next(bindings: 0) == .commit)
        #expect(LaunchOffer.begin.next(bindings: 1) == .binding(0))
        #expect(LaunchOffer.binding(0).next(bindings: 1) == .commit)
        #expect(LaunchOffer.binding(14).next(bindings: 16) == .binding(15))
        #expect(LaunchOffer.binding(15).next(bindings: 16) == .commit)
        #expect(LaunchOffer.commit.next(bindings: 16) == .commit)
    }

    @Test func launchSucceedsEndToEnd() throws {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        let original = host.shelves["Shell.elf"]!.bytes
        #expect(accept(&supervisor, &host) == nil)
        let nonce = try #require(supervisor.records[0]?.nonce)
        drive(&supervisor, &host)
        #expect(host.replies.count == 1)
        #expect(host.replies.first?.1 == .ok && host.replies.first?.delivered == true)
        let job = try #require(host.replies.first?.2)
        let task = try #require(host.tasks[job])
        var source = MemoryProgram(original)
        guard case .success(let plan) = ELFPlanner.plan(from: &source) else { Issue.record("fixture does not plan"); return }
        #expect(TaskImage(bytes: task.bytes).matches(plan, in: original))
        let bindings = ProgramProfile.shell.bindings
        var offered = 0
        for effect in host.effects {
            guard case .send(let endpoint, .binding(let index), let message, let grant, let rights) = effect else { continue }
            #expect(index == offered)
            #expect(endpoint == task.bootstrap)
            #expect(message.words[0] == bindings.storage[index]?.binding.rawValue)
            #expect(message.words[2] == nonce)
            #expect(grant == host.bindings[bindings.storage[index]!.binding])
            #expect(rights == bindings.storage[index]?.rights)
            offered += 1
        }
        #expect(offered == bindings.count)
        #expect(task.maps.count == plan.regionCount + 1)
        #expect(task.seals.count == plan.regionCount + 1)
        for index in 0..<plan.regionCount {
            let region = plan.region(at: index)!
            #expect(task.maps[index].0 == region.address && task.maps[index].1 == region.pages)
            #expect(task.seals[index].0 == region.address && task.seals[index].1 == region.pages)
            #expect(task.seals[index].2 == region.permissions)
        }
        #expect(task.seals.last?.0 == TaskABI.stackTop - TaskABI.pageSize)
        #expect(task.seals.last?.1 == 1 && task.seals.last?.2 == [.read, .write])
        #expect(task.context?.entry == plan.entry)
        #expect(task.context?.stack == TaskABI.stackTop)
        #expect(task.context?.programBreak == plan.programBreak)
        #expect(!host.live.contains(task.bootstrap))
        expectNothingHeld(host, supervised: [job])
        host.alive.remove(1)
        supervisor.reclaim(now: 0, host: &host)
        #expect(task.state == .running)
        task.die()
        supervisor.sweepJobs(host: &host)
        supervisor.sweepJobs(host: &host)
        #expect(host.reaped == [task.pid])
        expectNothingHeld(host)
    }

    @Test func refusesMalformedRequests() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        for (name, grant) in [(nil, false), (launchName(), true), (launchName("Other.elf"), false)] {
            #expect(supervisor.accept(name: name, carriesGrant: grant, requester: 1, now: 0,
                budget: 5000, rehearsal: .none, host: &host) == .badRequest)
        }
        #expect(host.effects.isEmpty)
    }

    @Test func anonymousRequesterIsRefused() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host, id: 0) == .badRequest)
        #expect(host.effects.isEmpty)
    }

    @Test func duplicateRequesterIsBusy() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        #expect(accept(&supervisor, &host) == .busy)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.ok])
    }

    @Test func fifthLaunchIsRefusedCapacity() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        for id in UInt32(1)...4 { #expect(accept(&supervisor, &host, id: id) == nil) }
        #expect(accept(&supervisor, &host, id: 5) == .capacity)
        drive(&supervisor, &host, until: { $0.state(of: 1) == nil })
        #expect(accept(&supervisor, &host, id: 5) == nil)
    }

    @Test func jobReservationHoldsAtCapacity() throws {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        for id in UInt32(1)...6 {
            #expect(accept(&supervisor, &host, id: id) == nil)
            drive(&supervisor, &host)
        }
        #expect(accept(&supervisor, &host, id: 7) == nil)
        #expect(accept(&supervisor, &host, id: 8) == nil)
        #expect(accept(&supervisor, &host, id: 9) == .capacity)
        for _ in 0..<200 where !supervisor.isEmpty {
            _ = supervisor.step(now: 0, host: &host)
            let records = (0..<4).filter { supervisor.records[$0] != nil }.count
            let jobs = (0..<8).filter { supervisor.jobs[$0] != nil }.count
            #expect(records + jobs <= 8)
        }
        #expect(supervisor.isEmpty)
        #expect(accept(&supervisor, &host, id: 9) == .capacity)
        let first = try #require(supervisor.jobs[0])
        host.tasks[first.handle]!.die()
        supervisor.sweepJobs(host: &host)
        #expect(accept(&supervisor, &host, id: 9) == nil)
    }

    @Test func missingBindingCreatesNothing() {
        let bindings = ProgramProfile.shell.bindings
        for index in 0..<bindings.count {
            var host = FakeLaunchHost()
            var supervisor = Supervisor(frequency: 1_000_000)
            let missing = bindings.storage[index]!.binding
            host.bindings[missing] = nil
            #expect(accept(&supervisor, &host) == .unavailable)
            #expect(sideEffects(host) == 0)
            #expect(supervisor.isEmpty)
            if missing != .console && missing != .profiler && missing != .programs {
                #expect(accept(&supervisor, &host, name: "Top.elf") == nil)
            }
        }
    }

    @Test func missingProgramsIsUnavailable() {
        for name in ["Shell.elf", "Top.elf"] {
            var host = FakeLaunchHost()
            host.bindings[.programs] = nil
            var supervisor = Supervisor(frequency: 1_000_000)
            #expect(accept(&supervisor, &host, name: name) == .unavailable)
            #expect(supervisor.isEmpty)
            #expect(sideEffects(host) == 0)
        }
    }

    @Test func unusableClockIsUnavailable() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 999)
        #expect(accept(&supervisor, &host) == .unavailable)
        #expect(supervisor.isEmpty)
    }

    @Test func missingProgramIsNotFound() {
        var host = FakeLaunchHost()
        host.shelves["Shell.elf"] = nil
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        #expect(supervisor.step(now: 0, host: &host))
        #expect(host.replies.map { $0.1 } == [.notFound])
        #expect(supervisor.isEmpty)
        #expect(host.tasks.isEmpty)
        expectNothingHeld(host)
    }

    @Test func busyProgramIsBusyAndNotWaited() {
        var host = FakeLaunchHost()
        let shelf = host.shelves["Shell.elf"]!
        #expect(shelf.lock(by: ProgramShelf.writer) == .ok)
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        #expect(supervisor.step(now: 0, host: &host))
        #expect(host.replies.map { $0.1 } == [.busy])
        #expect(shelf.claims == 1 && shelf.releases == 0)
        #expect(supervisor.isEmpty)
        expectNothingHeld(host)
    }

    @Test func malformedProgramLetsGo() {
        var host = FakeLaunchHost()
        host.shelves["Shell.elf"]!.bytes[1] = 0
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.malformedELF])
        expectNothingHeld(host)
    }

    @Test(arguments: ["create", "mapFirst", "mapStack", "write", "sealFirst", "sealStack", "context", "start"])
    func taskExhaustionRefusesAndRecovers(_ fault: String) throws {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        var source = MemoryProgram(patternedImage())
        guard case .success(let plan) = ELFPlanner.plan(from: &source) else { Issue.record("fixture does not plan"); return }
        switch fault {
            case "create": host.refuseCreate = true
            case "mapFirst": host.refuseMap = 0
            case "mapStack": host.refuseMap = plan.regionCount
            case "write": host.refuseWrite = 1
            case "sealFirst": host.refuseSeal = 0
            case "sealStack": host.refuseSeal = plan.regionCount
            case "context": host.refuseContext = true
            default: host.refuseStart = true
        }
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.taskFailure])
        #expect(host.tasks.values.allSatisfy { $0.state == .aborted })
        #expect(host.reaped.isEmpty)
        expectNothingHeld(host)
        host.refuseCreate = false; host.refuseMap = nil; host.refuseWrite = nil
        host.refuseSeal = nil; host.refuseContext = false; host.refuseStart = false
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.taskFailure, .ok])
        let job = try #require(host.replies.last?.2)
        host.tasks[job]!.die()
        supervisor.sweepJobs(host: &host)
        expectNothingHeld(host)
    }

    @Test func nonceWraps() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        supervisor.nextNonce = UInt32.max
        #expect(accept(&supervisor, &host) == nil)
        #expect(accept(&supervisor, &host, id: 2) == nil)
        #expect(supervisor.records[0]?.nonce == UInt32.max)
        #expect(supervisor.records[1]?.nonce == 1)
    }

    @Test func twoLaunchesNeverShareANonceOrEndpoint() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        #expect(accept(&supervisor, &host, id: 2, name: "Top.elf") == nil)
        let first = supervisor.records[0]!.nonce, second = supervisor.records[1]!.nonce
        #expect(first != 0 && second != 0 && first != second)
        drive(&supervisor, &host)
        #expect(host.replies.count == 2)
        #expect(Set(host.tasks.values.map { $0.bootstrap }).count == 2)
        #expect(host.replies.allSatisfy { $0.1 == .ok })
    }
}
