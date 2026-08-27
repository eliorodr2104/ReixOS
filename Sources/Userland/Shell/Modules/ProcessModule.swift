//
//  ProcessModule.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

public enum ProcessModule: ShellModule {

    public static let receiver: StaticString = "process"

    public static func handle(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellOutcome {
        handleResult(command, in: &session).outcome
    }

    public static func handleResult(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellCommandResult {
        var records = ShellResult()

        if session.spells(command.verb, "list") {
            guard Verbs.processList.accepts(command.argumentCount) else {
                _ = records.appendPresentation("  process.list takes no arguments\n")
                return ShellCommandResult(outcome: .handled, status: .refused, records: records)
            }
            list(authority: session.environment.profiler, into: &records)
            return ShellCommandResult(outcome: .handled, records: records)
        }

        guard session.spells(command.verb, "spawn") else {
            return ShellCommandResult(outcome: .notHandled, records: records)
        }
        guard Verbs.processSpawn.accepts(command.argumentCount) else {
            _ = records.appendPresentation("  process.spawn takes one name, as in process.spawn(\"Top.elf\")\n")
            return ShellCommandResult(outcome: .handled, status: .refused, records: records)
        }
        guard let name = session.bytes(of: command.arguments[0]) else {
            _ = records.appendPresentation("  that is not part of the line this shell read\n")
            return ShellCommandResult(outcome: .handled, status: .refused, records: records)
        }

        spawn(name.bytes, length: name.count, environment: session.environment, into: &records)
        return ShellCommandResult(outcome: .handled, records: records)
    }

    public static func describe() {}

    public static func listValue(authority: UInt32?) -> TypedShellInvocationResult {
        guard let authority else { return .failure(1) }
        var sequence = ShellSequence()
        sequence.beginBatch()
        var stats = ProcessStats()
        var pid   = UInt64(0)
        while true {
            let next = nextProcessStats(after: pid, into: &stats, authority: authority)
            guard next != UInt64.max else { break }
            pid = next
            let name = stats.name.span.withUnsafeBufferPointer {
                ShellText($0.baseAddress!, count: Int(stats.nameLength))
            }
            guard let name else { return .failure(2) }
            let object = ShellObject(
                kind   : UInt16(truncatingIfNeeded: stats.status),
                name   : name,
                number0: stats.pid,
                flags  : UInt32(stats.status)
            )
            if case .failure(.materializationLimit(let limit)) = sequence.append(object) {
                return .materializationLimit(limit)
            }
        }
        return .sequence(sequence)
    }
}

private func list(
      authority   : UInt32?,
      into records: inout ShellResult
) {
    guard let authority else {
        _ = records.appendPresentation("this shell was not given the authority to read the process table\n")
        return
    }

    _ = records.appendProcessList()
    var stats = ProcessStats()
    var pid   = UInt64(0)

    while true {
        let next = nextProcessStats(after: pid, into: &stats, authority: authority)
        guard next != UInt64.max else { break }
        pid = next
        guard records.appendProcess(
            pid   : stats.pid,
            status: UInt32(stats.status),
            name  : stats.name,
            count : Int(stats.nameLength)
        ) else { break }
    }

    _ = records.appendPresentation("\n")
}

private func spawn(
    _ name: UnsafePointer<UInt8>,
    length: Int,
    environment: Environment,
    into records: inout ShellResult
) {
    guard let console = environment.console else {
        _ = records.appendProcessStart(0, name: name, count: length)
        return
    }

    let result = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 2
    ) { grants in
        var count = 0
        grants[count] = CapGrant(
            source: console,
            slot  : BootCap.console.rawValue,
            rights: [.send, .grant]
        )
        count += 1

        if let profiler = environment.profiler {
            grants[count] = ProfileAuthorityGrant.tool(source: profiler)
            count += 1
        }

        return spawnProcess(
            path  : name,
            length: length,
            grants: grants.baseAddress!,
            count : count
        )
    }

    guard result.pid != UInt64.max else {
        _ = records.appendProcessStart(1, name: name, count: length)
        return
    }

    _ = records.appendProcessExit(pid: result.pid, code: reapChild(for: result.pid))
}
