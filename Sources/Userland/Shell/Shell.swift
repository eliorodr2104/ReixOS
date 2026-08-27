//
//  Shell.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// The terminal, written against `Terminal` and the capabilities this process
/// was handed, and against nothing else.
///
/// Commands are spelled `receiver.verb(arguments)` from the first version on,
/// because that shape is not a style: the receiver names the authority the
/// command is exercised through. `process.spawn("Top.elf")` is a use of a
/// capability this shell holds, and a shell that did not hold it would have no
/// `process` to type. The structured terminal this system is aiming at grows
/// out of that sentence, not out of a list of bare words.
@_cdecl("_start")
public func main() {

    let environment = Runtime.bootstrap()

    guard let service = environment.terminal else {
        print("[ SHELL ] no terminal to read from")
        exit(code: 1)
    }

    guard var terminal = Terminal(endpoint: service) else {
        print("[ SHELL ] the terminal refused to register this reader")
        exit(code: 1)
    }

    print("")
    print("ReixOS shell. Type shell.help() to see what this understands.")
    print("")

    var line = InlineArray<128, UInt8>(repeating: 0)

    while true {
        let count = terminal.readLine(prompt: prompt, into: &line)

        // The terminal is gone. Nothing this process does afterwards would be
        // read by anybody, so it stops rather than spinning on a dead handle.
        guard count >= 0 else {
            print("[ SHELL ] the terminal went away")
            exit(code: 1)
        }

        guard count > 0 else { continue }

        line.span.withUnsafeBufferPointer { buffer in
            run(buffer.baseAddress!, count: count, environment: environment)
        }
    }
}


private let prompt: StaticString = "reix> "


/// Parses one line and carries it out, or explains why it could not.
private func run(
    _ line: UnsafePointer<UInt8>,
    count : Int,
    environment: Environment
) {
    switch CommandParser.parse(line, count: count) {
        case .failure(let failure):
            guard case .empty = failure.reason else {
                report(failure)
                return
            }

        case .success(let command):
            dispatch(command, line: line, environment: environment)
    }
}


/// Prints the reason under a caret at the column that broke.
private func report(_ failure: ParseFailure) {
    var column = failure.column + prompt.utf8CodeUnitCount
    while column > 0 {
        putchar(ch: 0x20)
        column -= 1
    }

    print("^")
    print("       ", terminator: "")
    print(failure.message)
}


/// Carries out a parsed command, or says why it cannot.
///
/// A command with no receiver is looked for in each of them in turn. The order
/// is fixed and the verbs happen not to collide, which is what makes the rule
/// simple enough to state in one line of `help`. If two receivers ever want the
/// same verb, first-match-wins is the wrong answer and this should refuse the
/// line as ambiguous rather than pick one.
private func dispatch(
    _ command: Command,
    line     : UnsafePointer<UInt8>,
    environment: Environment
) {
    let named = command.receiver.count > 0

    if !named || matches(command.receiver, in: line, "shell") {
        if shellVerb(command, line: line) { return }

        if named {
            unknownVerb(command, line: line)
            return
        }
    }

    if !named || matches(command.receiver, in: line, "process") {
        if processVerb(command, line: line, environment: environment) { return }

        if named {
            unknownVerb(command, line: line)
            return
        }
    }

    guard named else {
        unknownVerb(command, line: line)
        return
    }

    print("no such receiver: ", terminator: "")
    printPadded(line + command.receiver.start, count: command.receiver.count, width: 0)
    print("")
    print("try help")
}


private func shellVerb(_ command: Command, line: UnsafePointer<UInt8>) -> Bool {
    guard matches(command.verb, in: line, "help") else { return false }

    help()
    return true
}


private func processVerb(
    _ command: Command,
    line     : UnsafePointer<UInt8>,
    environment: Environment
) -> Bool {

    if matches(command.verb, in: line, "list") {
        list(authority: environment.profiler)
        return true
    }

    guard matches(command.verb, in: line, "spawn") else { return false }

    guard command.argumentCount == 1 else {
        print("spawn takes one name, as in process.spawn(\"Top.elf\")")
        return true
    }

    spawn(command.arguments[0], line: line, environment: environment)
    return true
}


private func unknownVerb(_ command: Command, line: UnsafePointer<UInt8>) {
    print("no such verb: ", terminator: "")
    printPadded(line + command.verb.start, count: command.verb.count, width: 0)
    print("")
    print("try help")
}


private func help() {
    print("")
    print("  shell.help                this text")
    print("  process.list              the live process table")
    print("  process.spawn(\"Name.elf\") run an image and wait for it")
    print("")
    print("  Empty parentheses may be left off, and so may the receiver when")
    print("  the verb names only one thing: help, list and spawn(\"X\") all work.")
    print("")
    print("  A spawned program is given the console and the authority to read")
    print("  the process table, and nothing else. It cannot spawn children of")
    print("  its own: the kernel refuses, because this shell does not pass on")
    print("  the capability that would let it.")
    print("")
    print("  There is no way to interrupt a running program yet, so a program")
    print("  that does not end on its own holds the prompt until it does.")
    print("  Top.elf ends on its own.")
    print("")
}


/// The live process table, read through the profiler authority this shell was
/// granted and formatted here.
///
/// The kernel hands over `ProcessStats` values, not text: what is printed below
/// is this shell's opinion of how to show them, and a different reader would be
/// free to have another. That is the small end of the structured terminal.
private func list(authority: UInt32?) {
    guard let authority else {
        print("this shell was not given the authority to read the process table")
        return
    }

    print("")
    print("   PID  NAME              STATUS")

    var stats = ProcessStats()
    var pid   = UInt64(0)

    while true {
        let next = nextProcessStats(after: pid, into: &stats, authority: authority)
        guard next != UInt64.max else { break }

        pid = next

        printDecPadded(stats.pid, width: 6)
        print("  ", terminator: "")

        let width = 16
        var index = 0
        while index < Int(stats.nameLength), index < width {
            putchar(ch: stats.name[index])
            index += 1
        }
        while index < width {
            putchar(ch: 0x20)
            index += 1
        }

        print("  ", terminator: "")
        print(ProcessStatusCode(rawValue: stats.status)?.label ?? "unknown")
    }

    print("")
}


/// Runs an image and waits for it, with the console and nothing else.
///
/// The grant list is the point. It carries the console so the program can be
/// seen, and it deliberately carries no capability bearing the spawn right, so
/// the child is a process that cannot have children. That is not a convention
/// this shell keeps: `spawnProcess` in the kernel looks for the right and
/// refuses without it.
private func spawn(
    _ name: Span,
    line  : UnsafePointer<UInt8>,
    environment: Environment
) {
    guard let console = environment.console else {
        print("this shell has no console to hand on")
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

        // Narrowed to reading on the way in by `ProfileAuthorityGrant.tool`, so
        // a command can show the process table without also being able to dump
        // the trace ring over the console everybody shares.
        if let profiler = environment.profiler {
            grants[count] = ProfileAuthorityGrant.tool(source: profiler)
            count += 1
        }

        return spawnProcess(
            path  : line + name.start,
            length: name.count,
            grants: grants.baseAddress!,
            count : count
        )
    }

    guard result.pid != UInt64.max else {
        print("could not start ", terminator: "")
        printPadded(line + name.start, count: name.count, width: 0)
        print("")

        return
    }

    let code = reapChild(for: result.pid)

    print("[", terminator: "")
    printDec(result.pid, terminator: "")
    print("] exited with ", terminator: "")
    printDec(code, terminator: "")
    print("")
}


/// Whether a span of the typed line is exactly `text`.
private func matches(
    _ span: Span,
    in line: UnsafePointer<UInt8>,
    _ text : StaticString
) -> Bool {
    guard span.count == text.utf8CodeUnitCount else { return false }

    for index in 0..<span.count where line[span.start + index] != text.utf8Start[index] {
        return false
    }

    return true
}
