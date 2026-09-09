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

    enum Verb: UInt16 {
        case list, processes, spawn
    }

    public static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("ProcessManager", capability: .profiler, summary: "what is running")
    }

    public static var commandCount: Int { 3 }

    public static func command(at index: Int) -> ShellCommandDescriptor? {
        switch Verb(rawValue: UInt16(index)) {
            case .list:
                return ShellCommandDescriptor(
                    code      : Verb.list.rawValue,
                    verb      : "list",
                    signature : TypedShellSignature(namespace: "ProcessManager", name: "list", result: .sequence, namespaceRequired: true),
                    capability: .profiler,
                    schema    : .processes,
                    summary   : "the live process table"
                )
            case .processes:
                return ShellCommandDescriptor(
                    code      : Verb.processes.rawValue,
                    verb      : "list",
                    signature : TypedShellSignature(namespace: "ProcessManager", name: "processes", result: .sequence),
                    capability: .profiler,
                    schema    : .processes,
                    summary   : "the live process table, without naming the receiver"
                )
            case .spawn:
                return ShellCommandDescriptor(
                    code      : Verb.spawn.rawValue,
                    verb      : "spawn",
                    signature : TypedShellSignature(namespace: "ProcessManager", name: "spawn", TypedShellParameter("name")),
                    capability: .processServer,
                    summary   : "run an image and wait for it"
                )
            case nil:
                return nil
        }
    }

    /// Both spellings of the process table answer with the table itself, so
    /// neither takes the record path.
    public static func value(
        for code  : UInt16,
          in session: inout ShellSession
    ) -> TypedShellInvocationResult? {
        guard Verb(rawValue: code) == .list || Verb(rawValue: code) == .processes else { return nil }
        return listValue(authority: session.environment.profiler)
    }

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
    guard let processServer = environment.processServer else {
        _ = records.appendProcessStart(1, name: name, count: length)
        return
    }

    let result = launchProgram(
        through: processServer,
        name   : name,
        length : length
    )

    guard result.status == .ok, let job = result.job else {
        _ = records.appendProcessStart(1, name: name, count: length)
        return
    }

    let terminal = waitForJob(job)
    _ = records.appendJobExit(job: job, code: terminal.exitCode)
    _ = capDrop(job)
}
