//
//  ProcessServer.swift
//  ReixOS
//

import Reix
import ReixABI
import ProcessServerCore

/// Keeps launch requests moving while waiting children and departed callers are reclaimed.
public struct ProcessServer: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private static let launchBudgetMilliseconds: UInt64 = 5000
    private static let sweepMilliseconds       : UInt64 = 100
    private static let idleTicks               : UInt32 = 10
    private static let pollTicks               : UInt32 = 1

    #if REIX_BOOT_DIAGNOSTIC
    private static let lateBudgetMilliseconds: UInt64 = 300
    #endif

    public let serviceEndpoint: UInt32
    private var host          : SystemLaunchHost
    private var launches      : LaunchSupervisor<SystemLaunchHost>
    private let frequency     : UInt64

    public init(environment: Environment, endpoint: UInt32) {
        serviceEndpoint = endpoint
        frequency = readCounterFrequency()
        host = SystemLaunchHost(
            environment    : environment,
            files          : environment.programs.flatMap(FileSystemClient.init(fileSystem:)),
            serviceEndpoint: endpoint
        )
        launches = LaunchSupervisor(frequency: frequency)
    }

    public mutating func run() {
        UserBootPresentation.ready("[ PSRV  ] ProcessServer running")
        var nextSweep = LaunchDeadline(
            from        : readVirtualCounter(),
            milliseconds: Self.sweepMilliseconds,
            frequency   : frequency
        )
        var progressed = false
        var yielded    = false
        while true {
            let arrived: ReceivedMessage?
            if progressed {
                arrived = tryReceive(handle: serviceEndpoint)
            } else if !launches.isEmpty && !yielded {
                // One yield before sleeping, so a child that was just answered
                // runs now and not at the next tick.
                yield()
                yielded = true
                arrived = tryReceive(handle: serviceEndpoint)
            } else {
                arrived = receive(
                    handle : serviceEndpoint,
                    timeout: launches.isEmpty ? Self.idleTicks : Self.pollTicks
                )
            }
            if var request = arrived, request.arrived {
                if let operation = ProcessServerOperation(rawValue: request.message.tag.label) {
                    handle(operation, request: &request)
                } else {
                    _ = reply(message: ProcessServerStatus.badRequest.response, to: request.identity)
                }
                if let stray = request.takeGrant() { _ = capDrop(stray) }
            }
            let now = readVirtualCounter()
            progressed = launches.step(now: now, host: &host)
            if progressed { yielded = false }
            if nextSweep?.reached(at: now) ?? true {
                launches.reclaim(now: now, host: &host)
                launches.sweepJobs(host: &host)
                nextSweep = LaunchDeadline(
                    from        : now,
                    milliseconds: Self.sweepMilliseconds,
                    frequency   : frequency
                )
            }
        }
    }

    public mutating func handle(_ operation: ProcessServerOperation, request: inout ReceivedMessage) {
        switch operation {
            case .launch: launch(request: &request)
        }
    }

    private mutating func launch(request: inout ReceivedMessage) {
        launches.reclaim(now: readVirtualCounter(), host: &host)
        launches.sweepJobs(host: &host)
        var requested = ProcessLaunchRequest.name(from: request.message)
        var rehearsal: LaunchRehearsal = .none
        var budget = Self.launchBudgetMilliseconds
        #if REIX_BOOT_DIAGNOSTIC
        let dies = requested.map { Self.matches($0, "Shell.die") } ?? false
        if dies { requested = Self.programName("Shell.elf") }
        else if let name = requested {
            if Self.matches(name, "Top.late") {
                requested = Self.programName("Top.elf")
                rehearsal = .withholdCommit
                budget = Self.lateBudgetMilliseconds
            } else if Self.matches(name, "Top.mute") {
                requested = Self.programName("Top.elf")
                rehearsal = .withholdCommit
            } else if Self.matches(name, "Top.trap") {
                requested = Self.programName("Top.elf")
                rehearsal = .trapAtEntry
            }
        }
        #endif
        let refusal = launches.accept(
            name        : requested,
            carriesGrant: request.grantedCap != nil,
            requester   : request.identity,
            now         : readVirtualCounter(),
            budget      : budget,
            rehearsal   : rehearsal,
            host        : &host
        )
        if let refusal {
            _ = reply(message: refusal.response, to: request.identity)
            return
        }
        #if REIX_BOOT_DIAGNOSTIC
        if dies { host.diesOnCreate = true }
        #endif
    }

    #if REIX_BOOT_DIAGNOSTIC
    private static func matches(
        _ requested: (bytes: InlineArray<12, UInt8>, length: Int), _ text: StaticString
    ) -> Bool {
        guard requested.length == text.utf8CodeUnitCount else { return false }
        for index in 0..<requested.length where requested.bytes[index] != text.utf8Start[index] { return false }
        return true
    }

    private static func programName(_ text: StaticString) -> (bytes: InlineArray<12, UInt8>, length: Int) {
        var bytes = InlineArray<12, UInt8>(repeating: 0)
        for index in 0..<text.utf8CodeUnitCount { bytes[index] = text.utf8Start[index] }
        return (bytes, text.utf8CodeUnitCount)
    }
    #endif
}
