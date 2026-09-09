//
//  CoreModule.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

public enum CoreModule: ShellModule {

    /// This module's private name for each verb it declares.
    enum Verb: UInt16 {
        case help, exit, halt, clear
    }

    public static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("Shell", summary: "this shell itself")
    }

    public static var commandCount: Int { 4 }

    public static func command(at index: Int) -> ShellCommandDescriptor? {
        switch Verb(rawValue: UInt16(index)) {
            case .help:
                return ShellCommandDescriptor(
                    code     : Verb.help.rawValue,
                    verb     : "help",
                    signature: TypedShellSignature(
                        namespace: "Shell",
                        name     : "help",
                        TypedShellParameter("of", required: false),
                        effect   : .pure
                    ),
                    summary  : "what this shell understands, or what one receiver does"
                )
            case .clear:
                return ShellCommandDescriptor(
                    code     : Verb.clear.rawValue,
                    verb     : "clear",
                    signature: TypedShellSignature(namespace: "Shell", name: "clear", effect: .session),
                    summary  : "start the screen again, empty"
                )
            case .exit:
                return ShellCommandDescriptor(
                    code     : Verb.exit.rawValue,
                    verb     : "exit",
                    signature: TypedShellSignature(namespace: "Shell", name: "exit", effect: .session),
                    summary  : "stop this shell, leave the machine up"
                )
            case .halt:
                return ShellCommandDescriptor(
                    code      : Verb.halt.rawValue,
                    verb      : "halt",
                    signature : TypedShellSignature(namespace: "Shell", name: "halt", effect: .machine),
                    capability: .sessionControl,
                    sensitive : true,
                    summary   : "request a coordinated shutdown"
                )
            case nil:
                return nil
        }
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

        if session.spells(command.verb, "help") {
            guard Verbs.shellHelp.accepts(command.argumentCount) else {
                _ = records.appendPresentation("  Shell.help() or Shell.help(of: FileManager)\n")
                return ShellCommandResult(outcome: .handled, status: .refused, records: records)
            }
            if command.argumentCount == 1, let asked = session.bytes(of: command.arguments[0]) {
                help(about: asked.bytes, count: asked.count, in: session, into: &records)
            } else {
                help(in: session, into: &records)
            }
            return ShellCommandResult(outcome: .handled, records: records)
        }

        if session.spells(command.verb, "clear") {
            guard Verbs.shellClear.accepts(command.argumentCount) else {
                _ = records.appendPresentation("  Shell.clear takes no arguments\n")
                return ShellCommandResult(outcome: .handled, status: .refused, records: records)
            }
            return ShellCommandResult(outcome: .clearRequested, records: records)
        }

        if session.spells(command.verb, "exit") {
            guard Verbs.shellExit.accepts(command.argumentCount) else {
                _ = records.appendPresentation("  shell.exit takes no arguments\n")
                return ShellCommandResult(outcome: .handled, status: .refused, records: records)
            }
            return ShellCommandResult(outcome: .exitRequested, records: records)
        }

        guard session.spells(command.verb, "halt") else {
            return ShellCommandResult(outcome: .notHandled, records: records)
        }
        guard Verbs.shellHalt.accepts(command.argumentCount) else {
            _ = records.appendPresentation("  shell.halt takes no arguments\n")
            return ShellCommandResult(outcome: .handled, status: .refused, records: records)
        }

        halt(session.environment, into: &records)
        return ShellCommandResult(outcome: .handled, records: records)
    }

}

private func halt(
    _ environment : Environment,
      into records: inout ShellResult
) {
    guard let supervisor = environment.sessionControl else {
        _ = records.appendPower(0)
        return
    }

    guard case .success(let answer) = call(
        handle : supervisor,
        message: SessionControlOperation.shutdown.request
    ), answer.message.tag.label == SessionControlOperation.shutdown.rawValue,
       answer.message.tag.length == 1,
       answer.message.words[0] == SessionControlStatus.ok.rawValue
    else {
        _ = records.appendPower(2)
        return
    }

    _ = records.appendPower(1)
}

/// The whole of what this shell is, in the order somebody meeting it needs.
///
/// A banner, then what it holds, then what it does not, then how to write to
/// it. Every name and every line about a receiver comes out of the catalog, so
/// this says what the modules say and cannot drift from it.
private func help(
      in session: ShellSession,
      into records: inout ShellResult
) {
    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  ReixOS shell 0.1\n")
    _ = records.appendPresentation("  a terminal that says what it is allowed to do\n")
    _ = records.appendPresentation("\n")

    let catalog = session.catalog
    var held    = 0
    var withheld = 0
    for index in 0..<catalog.namespaceCount {
        guard let receiver = catalog.namespace(at: index) else { continue }
        if holds(receiver.capability, session.environment) { held += 1 } else { withheld += 1 }
    }

    if held > 0 {
        _ = records.appendPresentation("  This shell holds:\n")
        for index in 0..<catalog.namespaceCount {
            guard let receiver = catalog.namespace(at: index),
                  holds(receiver.capability, session.environment)
            else { continue }
            line(receiver, in: catalog, into: &records)
        }
    }
    if withheld > 0 {
        _ = records.appendPresentation("\n")
        _ = records.appendPresentation("  It was given no authority for:\n")
        for index in 0..<catalog.namespaceCount {
            guard let receiver = catalog.namespace(at: index),
                  !holds(receiver.capability, session.environment)
            else { continue }
            line(receiver, in: catalog, into: &records)
        }
    }

    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  Writing  receiver.verb(label: value). Parentheses, labels, quotes and\n")
    _ = records.appendPresentation("           the receiver may be left off where one thing answers, so\n")
    _ = records.appendPresentation("           `read a.txt` is `FileManager.read(at: \"a.txt\")`.\n")
    _ = records.appendPresentation("  Paths    reix::app/doc/x.txt crosses into a container with :: and\n")
    _ = records.appendPresentation("           walks folders with /. `..` goes up, and stops at the edge.\n")
    _ = records.appendPresentation("  Values   list.filter { $0.isFolder } or { entry in entry.isFolder }.\n")
    _ = records.appendPresentation("  Typing   Tab takes the grey word, or opens the box on what fits.\n")
    _ = records.appendPresentation("           Arrows move in it, Enter takes one, Esc closes it.\n")
    _ = records.appendPresentation("  Lines    Shift+Enter opens another line, Ctrl+Enter runs it now.\n")
    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  help FileManager  what one receiver can do\n")
    _ = records.appendPresentation("  help read         what one command takes and changes\n")
    _ = records.appendPresentation("\n")
}

/// One receiver, and how many commands of it this shell could actually run.
private func line(
    _ receiver: ShellNamespaceDescriptor,
      in catalog: ShellCatalog,
      into records: inout ShellResult
) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { row in
        var cursor = 0
        func put(_ text: StaticString) {
            for index in 0..<text.utf8CodeUnitCount where cursor < row.count {
                row[cursor] = text.utf8Start[index]
                cursor += 1
            }
        }
        func pad(to column: Int) {
            while cursor < column, cursor < row.count {
                row[cursor] = 0x20
                cursor += 1
            }
        }
        put("    ")
        put(receiver.name)
        pad(to: 20)
        put(receiver.summary)
        pad(to: 62)
        put("\n")
        _ = records.appendPresentation(bytes: row.baseAddress!, count: cursor)
    }
}

/// What one receiver can do, or what one command is.
private func help(
      about bytes: UnsafePointer<UInt8>,
      count      : Int,
      in session : ShellSession,
      into records: inout ShellResult
) {
    let catalog = session.catalog
    _ = records.appendPresentation("\n")

    // A receiver: everything it answers to, with what each one is for.
    for index in 0..<catalog.namespaceCount {
        guard let receiver = catalog.namespace(at: index),
              spells(bytes, count, receiver.name)
        else { continue }
        _ = records.appendPresentation("  ")
        _ = records.appendPresentation(receiver.name)
        _ = records.appendPresentation("\n")
        _ = records.appendPresentation("  ")
        _ = records.appendPresentation(receiver.summary)
        _ = records.appendPresentation("\n")
        if !holds(receiver.capability, session.environment) {
            _ = records.appendPresentation("  this shell was given no authority for it, so none of this runs\n")
        }
        _ = records.appendPresentation("\n")
        for position in 0..<catalog.count {
            guard let descriptor = catalog.command(at: position),
                  let owner = catalog.receiver(ofCommandAt: position),
                  spells(bytes, count, owner.name)
            else { continue }
            entry(descriptor, into: &records)
        }
        _ = records.appendPresentation("\n")
        return
    }

    // A command: what it takes, what it answers, what it changes.
    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index),
              spells(bytes, count, descriptor.signature.name)
        else { continue }
        _ = records.appendPresentation("  ")
        _ = records.appendPresentation(descriptor.signature.namespace)
        _ = records.appendPresentation(".")
        _ = records.appendPresentation(descriptor.signature.name)
        _ = records.appendPresentation("\n")
        _ = records.appendPresentation("  ")
        _ = records.appendPresentation(descriptor.summary)
        _ = records.appendPresentation("\n")
        for position in 0..<descriptor.signature.parameterCount {
            guard let parameter = descriptor.signature.parameters[position] else { continue }
            _ = records.appendPresentation("    takes    ")
            _ = records.appendPresentation(parameter.label)
            _ = records.appendPresentation("\n")
        }
        _ = records.appendPresentation("    answers  ")
        _ = records.appendPresentation(descriptor.schema.isEmptyType ? "nothing to carry on with" : descriptor.schema.name)
        _ = records.appendPresentation("\n")
        if descriptor.sensitive {
            _ = records.appendPresentation("    changes  something a later command cannot put back\n")
        }
        _ = records.appendPresentation("\n")
        return
    }

    _ = records.appendPresentation("  no receiver and no command answers to that name\n")
    _ = records.appendPresentation("\n")
}

/// One command's line inside a receiver's help.
private func entry(
    _ descriptor: ShellCommandDescriptor,
      into records: inout ShellResult
) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { row in
        var cursor = 0
        func put(_ text: StaticString) {
            for index in 0..<text.utf8CodeUnitCount where cursor < row.count {
                row[cursor] = text.utf8Start[index]
                cursor += 1
            }
        }
        func pad(to column: Int) {
            while cursor < column, cursor < row.count {
                row[cursor] = 0x20
                cursor += 1
            }
        }
        put("    ")
        put(descriptor.signature.name)
        for position in 0..<descriptor.signature.parameterCount {
            guard let parameter = descriptor.signature.parameters[position] else { continue }
            put(position == 0 ? "(" : ", ")
            put(parameter.label)
            put(":")
        }
        if descriptor.signature.parameterCount > 0 { put(")") }
        pad(to: 30)
        put(descriptor.summary)
        if descriptor.sensitive { pad(to: 74); put(" !") }
        put("\n")
        _ = records.appendPresentation(bytes: row.baseAddress!, count: cursor)
    }
}

private func holds(
    _ capability: BootCap?,
    _ environment: Environment
) -> Bool {
    guard let capability else { return true }
    return environment.handle(capability) != nil
}

private func spells(
    _ bytes: UnsafePointer<UInt8>,
    _ count: Int,
    _ name : StaticString
) -> Bool {
    guard count == name.utf8CodeUnitCount else { return false }
    for index in 0..<count where bytes[index] != name.utf8Start[index] { return false }
    return true
}
