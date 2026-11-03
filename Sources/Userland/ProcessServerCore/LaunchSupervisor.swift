//
//  LaunchSupervisor.swift
//  ReixOS
//

import ReixABI

/// A launch advances with one deadline fixed at acceptance and one shared loader.
///
/// Four held calls stay below the kernel's parked-caller bound. Every accepted
/// launch reserves a job slot, so launches plus supervised jobs never exceed
/// `jobCapacity`, even when a cancelled job takes time to exit.
///
/// The kernel tears processes down. ProcessServer reaps each started job exactly
/// once, and only after reading `.exited` for it. ProcessServer never reaps an
/// `.aborted`, `.invalid`, `.configuring` or `.running` job. If a job is still
/// running after a cancel, ProcessServer supervises it until it exits.
public struct LaunchSupervisor<Host: LaunchHost> {
    public static var launchCapacity: Int { 4 }
    public static var jobCapacity   : Int { 8 }

    let frequency: UInt64
    var records   = InlineArray<4, LaunchRecord?>(repeating: nil)
    var jobs      = InlineArray<8, SupervisedJob?>(repeating: nil)
    var loader    : LaunchLoader<Host.File>? = nil
    var cursor    = 0
    var nextNonce : UInt32 = 1

    public init(frequency: UInt64) {
        self.frequency = frequency
    }

    public var isEmpty: Bool {
        for index in 0..<records.count where records[index] != nil { return false }
        return true
    }

    func state(of requester: UInt32) -> LaunchState? {
        for index in 0..<records.count {
            if let record = records[index], record.requester == requester { return record.state }
        }
        return nil
    }

    public mutating func accept(
        name        : (bytes: InlineArray<12, UInt8>, length: Int)?,
        carriesGrant: Bool,
        requester   : UInt32,
        now         : UInt64,
        budget milliseconds: UInt64,
        rehearsal   : LaunchRehearsal,
        host        : inout Host
    ) -> ProcessServerStatus? {
        guard !carriesGrant, let name else { return .badRequest }
        guard requester != 0 else { return .badRequest }
        guard let profile = ProgramProfile.identify(name.bytes, length: name.length) else { return .badRequest }
        var free: Int? = nil
        var occupied = 0
        for index in 0..<records.count {
            if let record = records[index] {
                if record.requester == requester { return .busy }
                occupied += 1
            } else if free == nil { free = index }
        }
        guard let slot = free else { return .capacity }
        for index in 0..<jobs.count where jobs[index] != nil { occupied += 1 }
        guard occupied < Self.jobCapacity else { return .capacity }
        guard host.handle(for: .programs) != nil else { return .unavailable }
        let bindings = profile.bindings
        for index in 0..<bindings.count {
            guard let spec = bindings.storage[index], host.handle(for: spec.binding) != nil else {
                return .unavailable
            }
        }
        guard let deadline = LaunchDeadline(from: now, milliseconds: milliseconds, frequency: frequency) else {
            return .unavailable
        }
        records[slot] = LaunchRecord(
            requester: requester, deadline: deadline, profile: profile,
            name: name.bytes, nameLength: name.length, nonce: takeNonce(), rehearsal: rehearsal
        )
        return nil
    }

    public mutating func step(now: UInt64, host: inout Host) -> Bool {
        for offset in 0..<records.count {
            let slot = (cursor + offset) % records.count
            if advance(slot, now: now, host: &host) {
                cursor = (slot + 1) % records.count
                return true
            }
        }
        return false
    }

    private mutating func advance(_ slot: Int, now: UInt64, host: inout Host) -> Bool {
        guard let record = records[slot] else { return false }
        if record.deadline.reached(at: now) {
            abandon(slot, reply: .timedOut, cause: .deadline, host: &host)
            return true
        }
        switch record.state {
            case .queued: return load(slot, host: &host)
            case .loading: return copy(slot, host: &host)
            case .sealing: return seal(slot, host: &host)
            case .offering(let offer): return self.offer(offer, slot: slot, host: &host)
            case .acknowledging, .awaitingReady: return listen(slot, host: &host)
        }
    }

    private mutating func load(_ slot: Int, host: inout Host) -> Bool {
        if loader != nil { return false }
        let record = records[slot]!
        do {
            var file = try host.openProgram(record.name, length: record.nameLength)
            let plan = try ProgramLoad.begin(&file)
            loader = LaunchLoader(slot: slot, file: file, plan: plan)
            records[slot]!.state = .loading
            guard let created = host.createTask(record.name, length: record.nameLength) else {
                abandon(slot, reply: .taskFailure, cause: nil, host: &host)
                return true
            }
            records[slot]!.task = created.task
            records[slot]!.bootstrap = created.bootstrap
            for index in 0..<plan.regionCount {
                guard let region = plan.region(at: index),
                      host.map(created.task, at: region.address, pages: region.pages)
                else {
                    abandon(slot, reply: .taskFailure, cause: nil, host: &host)
                    return true
                }
            }
            if !host.map(created.task, at: TaskABI.stackTop - TaskABI.pageSize, pages: 1) {
                abandon(slot, reply: .taskFailure, cause: nil, host: &host)
            }
        } catch {
            abandon(slot, reply: error, cause: nil, host: &host)
        }
        return true
    }

    private mutating func copy(_ slot: Int, host: inout Host) -> Bool {
        guard var loading = loader, loading.slot == slot, let task = records[slot]?.task else {
            abandon(slot, reply: .taskFailure, cause: nil, host: &host)
            return true
        }
        let moved = loading.copy.step(loading.plan, from: &loading.file) { address, bytes, count in
            host.write(task, at: address, bytes: bytes, count: count)
        }
        if !moved {
            loader = loading
            abandon(slot, reply: .taskFailure, cause: nil, host: &host)
            return true
        }
        if loading.copy.isDone(loading.plan) {
            loading.file.release()
            loading.claimed = false
            records[slot]!.state = .sealing
        }
        loader = loading
        return true
    }

    private mutating func seal(_ slot: Int, host: inout Host) -> Bool {
        guard let loading = loader, loading.slot == slot, let task = records[slot]?.task else {
            abandon(slot, reply: .taskFailure, cause: nil, host: &host)
            return true
        }
        let plan = loading.plan
        if records[slot]!.rehearsal == .trapAtEntry {
            var zero: UInt32 = 0
            let wrote = withUnsafeBytes(of: &zero) { bytes in
                host.write(task, at: plan.entry, bytes: bytes.baseAddress!, count: bytes.count)
            }
            if !wrote {
                abandon(slot, reply: .taskFailure, cause: nil, host: &host)
                return true
            }
        }
        for index in 0..<plan.regionCount {
            guard let region = plan.region(at: index),
                  host.seal(task, at: region.address, pages: region.pages, permissions: region.permissions)
            else {
                abandon(slot, reply: .taskFailure, cause: nil, host: &host)
                return true
            }
        }
        guard host.seal(task, at: TaskABI.stackTop - TaskABI.pageSize, pages: 1, permissions: [.read, .write]),
              host.setContext(task, entry: plan.entry, stack: TaskABI.stackTop, programBreak: plan.programBreak)
        else {
            abandon(slot, reply: .taskFailure, cause: nil, host: &host)
            return true
        }
        loader = nil
        guard let pid = host.start(task) else {
            abandon(slot, reply: .taskFailure, cause: nil, host: &host)
            return true
        }
        records[slot]!.pid = pid
        records[slot]!.state = .offering(.begin)
        return true
    }

    private mutating func offer(_ offer: LaunchOffer, slot: Int, host: inout Host) -> Bool {
        let record = records[slot]!
        let endpoint = record.bootstrap!
        if let incoming = host.tryReceive(endpoint) {
            if let grant = incoming.grant { host.drop(grant) }
            abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
            return true
        }
        if offer == .commit && record.rehearsal == .withholdCommit { return childGone(slot, host: &host) }
        let message: Message
        var grant : UInt32? = nil
        var rights: CapRights = []
        switch offer {
            case .begin:
                message = EnvironmentTransaction.begin(count: UInt32(record.profile.bindings.count), nonce: record.nonce)
            case .binding(let index):
                guard let spec = record.profile.bindings.storage[index], let handle = host.handle(for: spec.binding) else {
                    abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
                    return true
                }
                message = EnvironmentTransaction.binding(spec.binding, index: UInt32(index), nonce: record.nonce)
                grant = handle
                rights = spec.rights
            case .commit:
                message = EnvironmentTransaction.commit(nonce: record.nonce)
        }
        switch host.trySend(endpoint, message, grant: grant, rights: rights) {
            case .ok:
                records[slot]!.state = offer == .commit ? .awaitingReady : .acknowledging(offer)
                return true
            case .wouldBlock:
                return childGone(slot, host: &host)
            case .peerDied:
                if !childGone(slot, host: &host) {
                    abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
                }
                return true
            default:
                abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
                return true
        }
    }

    private mutating func listen(_ slot: Int, host: inout Host) -> Bool {
        let record = records[slot]!
        guard let incoming = host.tryReceive(record.bootstrap!) else { return childGone(slot, host: &host) }
        if let grant = incoming.grant {
            host.drop(grant)
            abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
            return true
        }
        let message = incoming.message
        switch record.state {
            case .acknowledging(let offer):
                guard message.tag.label == EnvironmentTransactionOperation.acknowledgement.rawValue,
                      message.tag.length == 2,
                      message.words[0] == offer.acknowledgementIndex,
                      message.words[1] == record.nonce
                else {
                    abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
                    return true
                }
                records[slot]!.state = .offering(offer.next(bindings: record.profile.bindings.count))
            case .awaitingReady:
                guard message.tag.label == EnvironmentTransactionOperation.ready.rawValue,
                      message.tag.length == 1, message.words[0] == record.nonce
                else {
                    abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
                    return true
                }
                finish(slot, host: &host)
            default:
                abandon(slot, reply: .bootstrapFailure, cause: nil, host: &host)
        }
        return true
    }

    private mutating func childGone(_ slot: Int, host: inout Host) -> Bool {
        guard host.state(of: records[slot]!.task!) != .running else { return false }
        abandon(slot, reply: .bootstrapFailure, cause: .programDied, host: &host)
        return true
    }

    private mutating func finish(_ slot: Int, host: inout Host) {
        let record = records[slot]!
        host.drop(record.bootstrap!)
        records[slot]!.bootstrap = nil
        if host.reply(.ok, to: record.requester, job: record.task) {
            if let free = freeJobSlot() {
                jobs[free] = SupervisedJob(handle: record.task!, pid: record.pid)
                records[slot] = nil
            } else {
                abandon(slot, reply: nil, cause: nil, host: &host)
            }
        } else {
            abandon(slot, reply: nil, cause: host.alive(record.requester) ? nil : .requesterGone, host: &host)
        }
    }

    private mutating func abandon(
        _ slot: Int,
        reply status: ProcessServerStatus?,
        cause : LaunchReclaim?,
        host  : inout Host
    ) {
        guard let record = records[slot] else { return }
        if loader?.slot == slot {
            if loader!.claimed { loader!.file.release() }
            loader = nil
        }
        switch record.state {
            case .queued:
                break
            case .loading, .sealing:
                if let task = record.task { host.abort(task); host.drop(task) }
                if let bootstrap = record.bootstrap { host.drop(bootstrap) }
            case .offering, .acknowledging, .awaitingReady:
                let job = record.task!
                host.cancel(job)
                switch host.state(of: job) {
                    case .exited:
                        host.reap(record.pid)
                        host.drop(job)
                    case .running, .configuring:
                        if let free = freeJobSlot() { jobs[free] = SupervisedJob(handle: job, pid: record.pid) }
                        else { host.drop(job) }
                    case .aborted, .invalid:
                        host.drop(job)
                }
                if let bootstrap = record.bootstrap { host.drop(bootstrap) }
        }
        records[slot] = nil
        if let cause { host.reclaimed(cause) }
        if let status { _ = host.reply(status, to: record.requester, job: nil) }
    }

    public mutating func reclaim(now: UInt64, host: inout Host) {
        for slot in 0..<records.count {
            guard let record = records[slot] else { continue }
            if !host.alive(record.requester) {
                abandon(slot, reply: nil, cause: .requesterGone, host: &host)
            } else if record.deadline.reached(at: now) {
                abandon(slot, reply: .timedOut, cause: .deadline, host: &host)
            }
        }
    }

    public mutating func sweepJobs(host: inout Host) {
        for slot in 0..<jobs.count {
            guard let job = jobs[slot] else { continue }
            switch host.state(of: job.handle) {
                // Only an exited job is a corpse to reap: reaping anything still
                // running would park this server in reapChild.
                case .exited:
                    host.reap(job.pid)
                    host.drop(job.handle)
                    jobs[slot] = nil
                case .aborted, .invalid:
                    host.drop(job.handle)
                    jobs[slot] = nil
                case .configuring, .running:
                    break
            }
        }
    }

    private func freeJobSlot() -> Int? {
        for slot in 0..<jobs.count where jobs[slot] == nil { return slot }
        return nil
    }

    private mutating func takeNonce() -> UInt32 {
        let value = nextNonce == 0 ? 1 : nextNonce
        nextNonce = value &+ 1
        return value
    }
}
