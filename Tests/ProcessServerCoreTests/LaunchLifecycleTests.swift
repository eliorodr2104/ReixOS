//
//  LaunchLifecycleTests.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

private let lifecycleStates: [LaunchState] = [
    .queued, .loading, .sealing, .offering(.begin), .acknowledging(.begin),
    .offering(.binding(3)), .acknowledging(.binding(3)), .offering(.commit), .awaitingReady,
]

private func waiting(at target: LaunchState, pendingReady: Bool = false) -> (Supervisor, FakeLaunchHost) {
    var host = FakeLaunchHost()
    var supervisor = Supervisor(frequency: 1_000_000)
    if case .acknowledging(let offer) = target { host.childPlans = [.silentAt(offer)] }
    if target == .awaitingReady && !pendingReady { host.childPlans = [.neverReady] }
    if target == .queued {
        #expect(accept(&supervisor, &host, id: 99) == nil)
        _ = supervisor.step(now: 0, host: &host)
    }
    let rehearsal: LaunchRehearsal = target == .offering(.commit) ? .withholdCommit : .none
    #expect(accept(&supervisor, &host, budget: 100, rehearsal: rehearsal) == nil)
    drive(&supervisor, &host, until: { $0.state(of: 1) == target })
    return (supervisor, host)
}

private func clearBlocker(_ supervisor: inout Supervisor, _ host: inout FakeLaunchHost) {
    host.alive.remove(99)
    supervisor.reclaim(now: 0, host: &host)
}

@Suite("ProcessServer launch lifecycle")
struct LaunchLifecycleTests {
    @Test func deadBootstrapPeerIsReclaimed() {
        var (supervisor, host) = waiting(at: .offering(.begin))
        host.tasks.values.first!.die()
        host.sendStatus = .peerDied
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        #expect(host.reclaims == [.programDied])
        #expect(host.reaped == [100])
        expectNothingHeld(host)
    }

    @Test(arguments: ["label", "length", "nonce", "grant"])
    func malformedReadyIsRefused(_ fault: String) {
        var (supervisor, host) = waiting(at: .awaitingReady)
        let task = host.tasks.values.first!
        let nonce = supervisor.records[0]!.nonce
        var message = EnvironmentTransaction.ready(nonce: nonce)
        var grant: UInt32?
        switch fault {
            case "label": message = EnvironmentTransaction.refused(nonce: nonce)
            case "length": message = EnvironmentTransaction.acknowledgement(index: nonce, nonce: nonce)
            case "nonce": message = EnvironmentTransaction.ready(nonce: nonce &+ 1)
            default: grant = host.allocate()
        }
        task.child.outbox.append((message, grant))
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        #expect(host.reaped == [task.pid])
        expectNothingHeld(host)
    }

    @Test(arguments: [TaskState.configuring, .aborted, .invalid])
    func abandonReapsOnlyExitedJobs(_ state: TaskState) {
        var (supervisor, host) = waiting(at: .offering(.begin))
        let job = supervisor.records[0]!.task!
        host.tasks[job]!.state = state
        _ = supervisor.step(now: 100_000, host: &host)
        #expect(host.reaped.isEmpty)
        if state == .configuring {
            #expect(supervisor.jobs[0]?.handle == job)
            supervisor.sweepJobs(host: &host)
            #expect(host.reaped.isEmpty)
            host.tasks[job]!.die()
            supervisor.sweepJobs(host: &host)
            #expect(host.reaped == [100])
        }
        expectNothingHeld(host)
    }

    @Test(arguments: lifecycleStates)
    func deadlineExpiresAtEachState(_ target: LaunchState) {
        var (supervisor, host) = waiting(at: target)
        let started = host.tasks.values.filter { $0.state == .running }.map { $0.pid }
        #expect(supervisor.step(now: 100_000, host: &host))
        #expect(supervisor.state(of: 1) == nil)
        #expect(host.replies.filter { $0.0 == 1 }.map { $0.1 } == [.timedOut])
        #expect(host.reclaims == [.deadline])
        #expect(host.reaped == started)
        let reclaim = host.effects.firstIndex { if case .reclaim = $0 { return true }; return false }
        let reply = host.effects.firstIndex { if case .reply = $0 { return true }; return false }
        #expect((reclaim ?? Int.max) < (reply ?? 0))
        clearBlocker(&supervisor, &host)
        expectNothingHeld(host)
    }

    @Test(arguments: [LaunchState.queued, .awaitingReady])
    func reclaimExpiresWaitingLaunches(_ target: LaunchState) {
        var (supervisor, host) = waiting(at: target)
        supervisor.reclaim(now: 100_000, host: &host)
        #expect(supervisor.state(of: 1) == nil)
        #expect(host.replies.filter { $0.0 == 1 }.map { $0.1 } == [.timedOut])
        #expect(host.reclaims == [.deadline])
        clearBlocker(&supervisor, &host)
        expectNothingHeld(host)
    }

    @Test func deadlineIsAbsolute() {
        var host = FakeLaunchHost()
        host.ackDelay = 3
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host, budget: 100) == nil)
        for tick in 0...20 {
            _ = supervisor.step(now: UInt64(tick * 5000), host: &host)
            if tick < 20 { #expect(host.replies.isEmpty) }
        }
        #expect(host.replies.map { $0.1 } == [.timedOut])
        #expect(host.reclaims == [.deadline])
        expectNothingHeld(host)
    }

    @Test func deadlineIsSetAtAcceptance() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        _ = supervisor.step(now: 0, host: &host)
        #expect(accept(&supervisor, &host, id: 2, budget: 50) == nil)
        #expect(supervisor.state(of: 2) == .queued)
        #expect(supervisor.step(now: 50_000, host: &host))
        #expect(host.replies.filter { $0.0 == 2 }.map { $0.1 } == [.timedOut])
        #expect(supervisor.state(of: 2) == nil)
        host.alive.remove(1)
        supervisor.reclaim(now: 50_000, host: &host)
        expectNothingHeld(host)
    }

    @Test func deadlineWinsOverAPendingReady() {
        var (supervisor, host) = waiting(at: .awaitingReady, pendingReady: true)
        #expect(host.tasks.values.first?.child.outbox.first?.0.tag.label == EnvironmentTransactionOperation.ready.rawValue)
        _ = supervisor.step(now: 100_000, host: &host)
        #expect(host.replies.map { $0.1 } == [.timedOut])
        expectNothingHeld(host)
    }

    @Test(arguments: [
        FakeChild.Plan.dieBefore(.begin), .diesAfter(.begin), .dieBefore(.binding(0)),
        .diesAfter(.binding(5)), .dieBefore(.commit), .diesAfter(.commit),
    ])
    func childDeathAtEachState(_ plan: FakeChild.Plan) {
        var host = FakeLaunchHost()
        host.childPlans = [plan]
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        #expect(host.reclaims == [.programDied])
        #expect(host.reaped == [100])
        expectNothingHeld(host)
    }

    @Test func childRefusalFailsFast() {
        checkRefusal(.refuseAt(.binding(2)))
    }

    @Test func wrongNonceIsRefused() { checkRefusal(.wrongNonce) }
    @Test func wrongIndexIsRefused() { checkRefusal(.wrongIndex) }
    @Test func duplicateAckIsRefused() { checkRefusal(.duplicateAck) }
    @Test func grantOnAckIsDroppedAndRefused() { checkRefusal(.ackWithGrant) }

    private func checkRefusal(_ plan: FakeChild.Plan) {
        var host = FakeLaunchHost()
        host.childPlans = [plan]
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        #expect(host.reclaims.isEmpty)
        #expect(host.reaped == [100])
        expectNothingHeld(host)
    }

    @Test func unexpectedMessageWhileOfferingIsRefused() {
        var (supervisor, host) = waiting(at: .offering(.begin))
        let grant = host.allocate()
        host.tasks.values.first!.child.outbox.append((EnvironmentTransaction.ready(nonce: 1), grant))
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        #expect(!host.live.contains(grant))
        expectNothingHeld(host)
    }

    @Test func grantThatDoesNotLandIsRefused() {
        var host = FakeLaunchHost()
        host.rejectGrants = true
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        expectNothingHeld(host)
    }

    @Test(arguments: [IPCStatus.grantRejected, .invalidCapability, .peerDied])
    func transportRefusalFailsFast(_ status: IPCStatus) {
        var (supervisor, host) = waiting(at: .offering(.begin))
        host.sendStatus = status
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.map { $0.1 } == [.bootstrapFailure])
        expectNothingHeld(host)
    }

    @Test(arguments: [LaunchState.queued, .loading, .sealing, .offering(.begin),
        .acknowledging(.binding(1)), .offering(.commit), .awaitingReady])
    func orphanReclaimedAtEachState(_ target: LaunchState) {
        var (supervisor, host) = waiting(at: target)
        let started = host.tasks.values.filter { $0.state == .running }.map { $0.pid }
        host.alive.remove(1)
        supervisor.reclaim(now: 0, host: &host)
        #expect(host.replies.filter { $0.0 == 1 }.isEmpty)
        #expect(supervisor.state(of: 1) == nil)
        #expect(host.reclaims == [.requesterGone])
        #expect(host.reaped == started)
        clearBlocker(&supervisor, &host)
        expectNothingHeld(host)
    }

    @Test func requesterDiesAtReply() {
        var (supervisor, host) = waiting(at: .awaitingReady, pendingReady: true)
        host.alive.remove(1)
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.count == 1 && host.replies.first?.delivered == false)
        #expect(host.reclaims == [.requesterGone])
        #expect(supervisor.isEmpty)
        #expect((0..<8).allSatisfy { supervisor.jobs[$0] == nil })
        #expect(host.reaped == [100])
        expectNothingHeld(host)
    }

    @Test func replyGrantRejectedCancelsChild() {
        var (supervisor, host) = waiting(at: .awaitingReady, pendingReady: true)
        host.replyRefused.insert(1)
        _ = supervisor.step(now: 0, host: &host)
        #expect(host.replies.first?.delivered == false)
        #expect(host.reclaims.isEmpty)
        #expect(host.reaped == [100])
        expectNothingHeld(host)
    }

    @Test func sweepReapsOnlyExitedJobs() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        for id in UInt32(1)...4 {
            #expect(accept(&supervisor, &host, id: id) == nil)
            drive(&supervisor, &host)
        }
        let states: [TaskState] = [.exited, .aborted, .invalid, .running]
        for index in 0..<4 { host.tasks[supervisor.jobs[index]!.handle]!.state = states[index] }
        let kept = supervisor.jobs[3]!.handle
        supervisor.sweepJobs(host: &host)
        supervisor.sweepJobs(host: &host)
        #expect(host.reaped == [100])
        #expect((0..<3).allSatisfy { supervisor.jobs[$0] == nil })
        #expect(supervisor.jobs[3]?.handle == kept)
        expectNothingHeld(host, supervised: [kept])
    }

    @Test func cancelledJobStillRunningIsSupervised() {
        var (supervisor, host) = waiting(at: .awaitingReady)
        host.cancelLeavesRunning = true
        _ = supervisor.step(now: 100_000, host: &host)
        #expect(host.reaped.isEmpty)
        #expect(host.replies.map { $0.1 } == [.timedOut])
        guard let job = supervisor.jobs[0] else { Issue.record("cancelled running job was lost"); return }
        #expect(host.tasks[job.handle]?.state == .running)
        expectNothingHeld(host, supervised: [job.handle])
        host.tasks[job.handle]!.die()
        supervisor.sweepJobs(host: &host)
        #expect(host.reaped == [job.pid])
        expectNothingHeld(host)
    }

    @Test func stepAdvancesOneLaunch() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host, until: { $0.state(of: 1) == .offering(.begin) })
        #expect(accept(&supervisor, &host, id: 2, name: "Top.elf") == nil)
        for _ in 0..<5 {
            let a = supervisor.state(of: 1), b = supervisor.state(of: 2)
            let index = supervisor.loader?.copy.index, offset = supervisor.loader?.copy.offset
            #expect(supervisor.step(now: 0, host: &host))
            let changedA = a != supervisor.state(of: 1)
            let changedB = b != supervisor.state(of: 2) || index != supervisor.loader?.copy.index || offset != supervisor.loader?.copy.offset
            #expect(changedA != changedB)
        }
    }

    @Test func loadingCopiesOnePagePerStep() {
        var (supervisor, host) = waiting(at: .loading)
        let shelf = host.shelves["Shell.elf"]!
        for _ in 0..<1000 {
            if supervisor.state(of: 1) != .loading { break }
            let reads = shelf.reads
            let before = host.effects.count
            _ = supervisor.step(now: 0, host: &host)
            let writes = host.effects[before...].filter { if case .write = $0 { return true }; return false }
            #expect(shelf.reads == reads + 1)
            #expect(writes.count == 1)
        }
        #expect(supervisor.state(of: 1) == .sealing)
    }

    @Test func bootstrapStepIsBounded() {
        var (supervisor, host) = waiting(at: .offering(.begin))
        host.ackDelay = 2
        host.tasks.values.first!.child.startDelay = 2
        for _ in 0..<200 where !supervisor.isEmpty {
            let before = host.effects.count
            _ = supervisor.step(now: 0, host: &host)
            let effects = host.effects[before...]
            #expect(effects.filter { if case .receive = $0 { return true }; return false }.count <= 1)
            #expect(effects.filter { if case .send = $0 { return true }; return false }.count <= 1)
            #expect(effects.filter { if case .state = $0 { return true }; return false }.count <= 1)
        }
        #expect(host.replies.map { $0.1 } == [.ok])
    }

    @Test func waitingLaunchProgressesBetweenChunks() {
        var host = FakeLaunchHost()
        // Top has already let go of the loader when Shell begins its longer copy.
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host, id: 2, name: "Top.elf") == nil)
        drive(&supervisor, &host, until: { $0.state(of: 2) == .offering(.begin) })
        let shelf = host.shelves["Shell.elf"]!
        shelf.bytes = largerPatternedImage()
        #expect(accept(&supervisor, &host) == nil)
        drive(&supervisor, &host, until: { $0.state(of: 1) == .loading })
        #expect(supervisor.state(of: 2) != nil)
        drive(&supervisor, &host, until: { $0.state(of: 2) == nil })
        #expect(host.replies.filter { $0.0 == 2 }.map { $0.1 } == [.ok])
        #expect(supervisor.state(of: 1) == .loading)
    }

    @Test func secondLaunchWaitsForLoader() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host) == nil)
        #expect(accept(&supervisor, &host, id: 2) == nil)
        _ = supervisor.step(now: 0, host: &host)
        let shelf = host.shelves["Shell.elf"]!
        for _ in 0..<1000 {
            if supervisor.state(of: 1) == .offering(.begin) { break }
            #expect(supervisor.state(of: 2) == .queued)
            #expect(shelf.claims == 1)
            _ = supervisor.step(now: 0, host: &host)
        }
        drive(&supervisor, &host)
        #expect(shelf.claims == 2 && shelf.releases == 2)
        #expect(host.replies.map { $0.1 } == [.ok, .ok])
    }

    @Test func writesRefusedUntilLastChunk() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        let shelf = host.shelves["Shell.elf"]!
        var refusals: [FSStatus] = []
        shelf.onRead = { shelf, _ in refusals.append(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer)) }
        #expect(accept(&supervisor, &host) == nil)
        _ = supervisor.step(now: 0, host: &host)
        for _ in 0..<1000 {
            if supervisor.state(of: 1) != .loading { break }
            #expect(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer) == .busy)
            _ = supervisor.step(now: 0, host: &host)
        }
        #expect(supervisor.state(of: 1) == .sealing)
        #expect(!refusals.isEmpty && refusals.allSatisfy { $0 == .busy })
        var source = MemoryProgram(shelf.bytes)
        guard case .success(let plan) = ELFPlanner.plan(from: &source), let task = host.tasks.values.first else {
            Issue.record("fixture does not plan or task missing"); return
        }
        #expect(TaskImage(bytes: task.bytes).matches(plan, in: shelf.bytes))
        #expect(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer) == .ok)
    }

    @Test func removeRefusedWhileLoading() {
        var (supervisor, host) = waiting(at: .loading)
        let shelf = host.shelves["Shell.elf"]!
        #expect(shelf.remove(by: ProgramShelf.writer) == .busy)
        drive(&supervisor, &host, until: { $0.state(of: 1) == .sealing })
        #expect(shelf.remove(by: ProgramShelf.writer) == .ok)
    }

    @Test func withheldCommitTimesOut() {
        var (supervisor, host) = waiting(at: .offering(.commit))
        #expect(!supervisor.step(now: 99_999, host: &host))
        #expect(host.effects.allSatisfy { if case .send(_, .commit, _, _, _) = $0 { return false }; return true })
        _ = supervisor.step(now: 100_000, host: &host)
        #expect(host.replies.map { $0.1 } == [.timedOut])
        expectNothingHeld(host)
    }

    @Test func trapRehearsalZeroesEntry() {
        var host = FakeLaunchHost()
        var supervisor = Supervisor(frequency: 1_000_000)
        #expect(accept(&supervisor, &host, rehearsal: .trapAtEntry) == nil)
        drive(&supervisor, &host, until: { $0.state(of: 1) == .offering(.begin) })
        let task = host.tasks.values.first!
        guard let context = task.context, let firstSeal = task.firstSealAt else { Issue.record("no context or seals"); return }
        for byte in 0..<4 { #expect(task.bytes[context.entry + UInt64(byte)] == 0) }
        let writes = host.effects.enumerated().compactMap { index, effect -> (Int, UInt64, Int)? in
            if case .write(let address, let count) = effect { return (index, address, count) }; return nil
        }
        #expect(writes.last?.1 == context.entry && writes.last?.2 == 4)
        #expect((writes.last?.0 ?? Int.max) < firstSeal)
        #expect(writes.count > 1)
    }
}

private func largerPatternedImage() -> [UInt8] {
    var bytes = patternedImage()
    let count = 40 * 4096
    bytes += [UInt8](repeating: 0xA5, count: 0x3000 + count - bytes.count)
    for offset in [64 + 2 * 56 + 32, 64 + 2 * 56 + 40] {
        for byte in 0..<8 { bytes[offset + byte] = UInt8(truncatingIfNeeded: count >> (byte * 8)) }
    }
    return bytes
}
