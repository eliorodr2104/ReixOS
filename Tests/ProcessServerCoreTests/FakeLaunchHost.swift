//
//  FakeLaunchHost.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

struct FakeChild {
    enum Plan {
        case cooperate
        case dieBefore(LaunchOffer), diesAfter(LaunchOffer), silentAt(LaunchOffer), refuseAt(LaunchOffer)
        case wrongNonce, wrongIndex, duplicateAck, ackWithGrant, neverReady
    }
    var plan      : Plan = .cooperate
    var parked    = true
    var outbox    : [(Message, UInt32?)] = []
    var expecting : LaunchOffer = .begin
    var bindingCount = 0
    var startDelay = 0
    var ackDelay   = 0
}

final class FakeTask {
    var state: TaskState = .configuring
    let bootstrap: UInt32
    let pid: UInt64
    var maps : [(UInt64, UInt32)] = []
    var bytes: [UInt64: UInt8] = [:]
    var seals: [(UInt64, UInt32, TaskMemoryPermissions)] = []
    var context: (entry: UInt64, stack: UInt64, programBreak: UInt64)?
    var child: FakeChild
    var firstSealAt: Int?
    var writes = 0

    init(bootstrap: UInt32, pid: UInt64, child: FakeChild) {
        self.bootstrap = bootstrap
        self.pid = pid
        self.child = child
    }

    func die() {
        state = .exited
        child.outbox.removeAll()
        child.parked = false
    }
}

final class FakeLaunchHost: LaunchHost {
    typealias File = ShelfProgram
    enum Effect {
        case handle(EnvironmentBinding), open, create, map, write(UInt64, Int), seal, context, start
        case abort, cancel, state, reap, drop(UInt32), send(UInt32, LaunchOffer, Message, UInt32?, CapRights)
        case receive, alive, reply, reclaim
    }

    var shelves: [String: ProgramShelf] = ["Shell.elf": ProgramShelf(patternedImage()), "Top.elf": ProgramShelf(patternedImage())]
    var filesAvailable = true
    var bindings: [EnvironmentBinding: UInt32] = [:]
    var live: Set<UInt32> = []
    var requesterCopies: Set<UInt32> = []
    var nextHandle: UInt32 = 0x1000
    var tasks: [UInt32: FakeTask] = [:]
    var childPlans: [FakeChild.Plan] = []
    var startDelay = 0
    var ackDelay = 0
    var refuseCreate = false
    var refuseMap: Int?
    var refuseWrite: Int?
    var refuseSeal: Int?
    var refuseContext = false
    var refuseStart = false
    var cancelLeavesRunning = false
    var rejectGrants = false
    var sendStatus: IPCStatus?
    var alive: Set<UInt32> = []
    var replyRefused: Set<UInt32> = []
    var replies: [(UInt32, ProcessServerStatus, UInt32?, delivered: Bool)] = []
    var reaped: [UInt64] = []
    var reclaims: [LaunchReclaim] = []
    var effects: [Effect] = []

    init() {
        for raw in UInt32(0)...23 {
            if let binding = EnvironmentBinding(rawValue: raw) { bindings[binding] = 0x100 + raw }
        }
    }

    func allocate() -> UInt32 {
        let handle = nextHandle
        nextHandle += 1
        live.insert(handle)
        return handle
    }

    func handle(for binding: EnvironmentBinding) -> UInt32? {
        effects.append(.handle(binding))
        return bindings[binding]
    }

    func openProgram(_ name: InlineArray<12, UInt8>, length: Int) throws(ProcessServerStatus) -> ShelfProgram {
        effects.append(.open)
        guard filesAvailable else { throw .unavailable }
        let key = String(decoding: (0..<length).map { name[$0] }, as: UTF8.self)
        guard let shelf = shelves[key] else { throw .notFound }
        return ShelfProgram(shelf)
    }

    func createTask(_ name: InlineArray<12, UInt8>, length: Int) -> (task: UInt32, bootstrap: UInt32)? {
        effects.append(.create)
        guard !refuseCreate else { return nil }
        let task = allocate(), bootstrap = allocate()
        var child = FakeChild(plan: childPlans.isEmpty ? .cooperate : childPlans.removeFirst())
        child.startDelay = startDelay
        tasks[task] = FakeTask(bootstrap: bootstrap, pid: UInt64(100 + tasks.count), child: child)
        return (task, bootstrap)
    }

    func map(_ task: UInt32, at address: UInt64, pages: UInt32) -> Bool {
        effects.append(.map)
        let image = tasks[task]!
        guard refuseMap != image.maps.count else { return false }
        image.maps.append((address, pages))
        return true
    }

    func write(_ task: UInt32, at address: UInt64, bytes: UnsafeRawPointer, count: Int) -> Bool {
        effects.append(.write(address, count))
        let image = tasks[task]!
        let index = image.writes
        image.writes += 1
        guard refuseWrite != index else { return false }
        for byte in 0..<count { image.bytes[address + UInt64(byte)] = bytes.load(fromByteOffset: byte, as: UInt8.self) }
        return true
    }

    func seal(_ task: UInt32, at address: UInt64, pages: UInt32, permissions: TaskMemoryPermissions) -> Bool {
        effects.append(.seal)
        let image = tasks[task]!
        guard refuseSeal != image.seals.count else { return false }
        if image.firstSealAt == nil { image.firstSealAt = effects.count - 1 }
        image.seals.append((address, pages, permissions))
        return true
    }

    func setContext(_ task: UInt32, entry: UInt64, stack: UInt64, programBreak: UInt64) -> Bool {
        effects.append(.context)
        guard !refuseContext else { return false }
        tasks[task]!.context = (entry, stack, programBreak)
        return true
    }

    func start(_ task: UInt32) -> UInt64? {
        effects.append(.start)
        guard !refuseStart else { return nil }
        tasks[task]!.state = .running
        return tasks[task]!.pid
    }

    func abort(_ task: UInt32) {
        effects.append(.abort)
        #expect(tasks[task]?.state == .configuring)
        tasks[task]?.state = .aborted
    }

    func cancel(_ job: UInt32) {
        effects.append(.cancel)
        if tasks[job]?.state == .running && !cancelLeavesRunning { tasks[job]?.die() }
    }

    func state(of job: UInt32) -> TaskState {
        effects.append(.state)
        return live.contains(job) ? tasks[job]?.state ?? .invalid : .invalid
    }

    func reap(_ pid: UInt64) {
        effects.append(.reap)
        guard tasks.values.first(where: { $0.pid == pid })?.state == .exited else {
            Issue.record("reaped a child before it exited")
            return
        }
        reaped.append(pid)
    }

    func drop(_ handle: UInt32) {
        effects.append(.drop(handle))
        if live.remove(handle) == nil { Issue.record("dropped twice or never held") }
    }

    func trySend(_ endpoint: UInt32, _ message: Message, grant: UInt32?, rights: CapRights) -> IPCStatus {
        guard let image = tasks.values.first(where: { $0.bootstrap == endpoint }) else { return .invalidCapability }
        let offer: LaunchOffer
        switch EnvironmentTransactionOperation(rawValue: message.tag.label) {
            case .begin: offer = .begin
            case .binding: offer = .binding(Int(message.words[1]))
            default: offer = .commit
        }
        effects.append(.send(endpoint, offer, message, grant, rights))
        if let sendStatus { return sendStatus }
        if case .dieBefore(let at) = image.child.plan, at == offer { image.die(); return .wouldBlock }
        guard image.state == .running, image.child.parked else { return .wouldBlock }
        if image.child.startDelay > 0 { image.child.startDelay -= 1; return .wouldBlock }
        #expect(image.child.expecting == offer)
        image.child.parked = false
        if offer == .begin { image.child.bindingCount = Int(message.words[1]) }
        image.child.expecting = offer.next(bindings: image.child.bindingCount)
        if case .diesAfter(let at) = image.child.plan, at == offer { image.die(); return .ok }
        if case .silentAt(let at) = image.child.plan, at == offer { return .ok }
        let nonce = offer == .commit ? message.words[0] : message.words[2]
        if case .refuseAt(let at) = image.child.plan, at == offer {
            image.child.outbox.append((EnvironmentTransaction.refused(nonce: nonce), nil))
        } else if rejectGrants && grant != nil {
            image.child.outbox.append((EnvironmentTransaction.refused(nonce: nonce), nil))
        } else if offer == .commit {
            if case .neverReady = image.child.plan { return .ok }
            image.child.outbox.append((EnvironmentTransaction.ready(nonce: nonce), nil))
        } else {
            var ack = EnvironmentTransaction.acknowledgement(index: offer.acknowledgementIndex, nonce: nonce)
            var ackGrant: UInt32?
            switch image.child.plan {
                case .wrongNonce: ack = EnvironmentTransaction.acknowledgement(index: offer.acknowledgementIndex, nonce: nonce &+ 1)
                case .wrongIndex: ack = EnvironmentTransaction.acknowledgement(index: 99, nonce: nonce)
                case .ackWithGrant: ackGrant = allocate()
                default: break
            }
            image.child.outbox.append((ack, ackGrant))
            if case .duplicateAck = image.child.plan { image.child.outbox.append((ack, nil)) }
        }
        image.child.ackDelay = ackDelay
        return .ok
    }

    func tryReceive(_ endpoint: UInt32) -> (message: Message, grant: UInt32?)? {
        effects.append(.receive)
        guard let image = tasks.values.first(where: { $0.bootstrap == endpoint }), !image.child.outbox.isEmpty else { return nil }
        if image.child.ackDelay > 0 { image.child.ackDelay -= 1; return nil }
        let incoming = image.child.outbox.removeFirst()
        image.child.parked = true
        return incoming
    }

    func alive(_ identity: UInt32) -> Bool {
        effects.append(.alive)
        return alive.contains(identity)
    }

    func reply(_ status: ProcessServerStatus, to identity: UInt32, job: UInt32?) -> Bool {
        effects.append(.reply)
        let delivered = alive.contains(identity) && !replyRefused.contains(identity)
        replies.append((identity, status, job, delivered))
        if delivered, job != nil { requesterCopies.insert(allocate()) }
        return delivered
    }

    func reclaimed(_ cause: LaunchReclaim) {
        effects.append(.reclaim)
        reclaims.append(cause)
    }
}

func launchName(_ text: String = "Shell.elf") -> (bytes: InlineArray<12, UInt8>, length: Int) {
    var bytes = InlineArray<12, UInt8>(repeating: 0)
    for (index, byte) in text.utf8.enumerated() { bytes[index] = byte }
    return (bytes, text.utf8.count)
}

typealias Supervisor = LaunchSupervisor<FakeLaunchHost>

@discardableResult
func accept(_ supervisor: inout Supervisor, _ host: inout FakeLaunchHost, id: UInt32 = 1,
            name: String = "Shell.elf", budget: UInt64 = 5000, now: UInt64 = 0,
            rehearsal: LaunchRehearsal = .none) -> ProcessServerStatus? {
    host.alive.insert(id)
    return supervisor.accept(name: launchName(name), carriesGrant: false, requester: id,
        now: now, budget: budget, rehearsal: rehearsal, host: &host)
}

func drive(_ supervisor: inout Supervisor, _ host: inout FakeLaunchHost, now: UInt64 = 0,
           until done: (Supervisor) -> Bool = { $0.isEmpty }) {
    for _ in 0..<1000 {
        if done(supervisor) { return }
        _ = supervisor.step(now: now, host: &host)
    }
    Issue.record("launch did not reach its expected state in 1000 steps")
}

func expectNothingHeld(_ host: FakeLaunchHost, supervised: Set<UInt32> = []) {
    #expect(host.live == host.requesterCopies.union(supervised))
    #expect(Set(host.reaped).count == host.reaped.count)
    for shelf in host.shelves.values {
        #expect(shelf.successfulClaims == shelf.releases)
        if shelf.successfulClaims > 0 { #expect(shelf.releasedForTheWriter()) }
    }
}

func sideEffects(_ host: FakeLaunchHost) -> Int {
    host.effects.filter { if case .handle = $0 { return false }; return true }.count
}
