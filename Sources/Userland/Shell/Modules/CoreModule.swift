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

    public static let receiver: StaticString = "shell"

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
                _ = records.appendPresentation("  shell.help takes no arguments\n")
                return ShellCommandResult(outcome: .handled, status: .refused, records: records)
            }
            help(into: &records)
            return ShellCommandResult(outcome: .handled, records: records)
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

    public static func describe() {}
}

private func halt(
    _ environment : Environment,
      into records: inout ShellResult
) {
    if let files = Files.attached(environment) {
        _ = records.appendUnmount(files.unmount().rawValue)
    }

    guard let authority = environment.power else {
        _ = records.appendPower(0)
        return
    }

    _ = records.appendPower(1)
    if !powerOff(authority: authority) {
        _ = records.appendPower(2)
    }
}

private func help(into records: inout ShellResult) {
    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  shell.help                this text\n")
    _ = records.appendPresentation("  shell.exit                stop this shell, leave the machine up\n")
    _ = records.appendPresentation("  shell.halt                unmount the disk and stop the machine\n")
    _ = records.appendPresentation("  process.list              the live process table\n")
    _ = records.appendPresentation("  process.spawn \"Name.elf\"  run an image and wait for it\n")
    _ = records.appendPresentation("  disk.info                 what the disk is\n")
    _ = records.appendPresentation("  disk.read 0               the first bytes of one sector\n")
    _ = records.appendPresentation("  fileSystem.currentDirectory()             say where this shell is standing\n")
    _ = records.appendPresentation("  fileSystem.changeDir(at: reix::app/doc)   change this session's directory\n")
    _ = records.appendPresentation("  fileSystem.list()                         what is here\n")
    _ = records.appendPresentation("  fileSystem.free()                         how much room is left\n")
    _ = records.appendPresentation("  fileSystem.info(at: a.txt)                what something is, and when\n")
    _ = records.appendPresentation("  fileSystem.read(at: a.txt)                 the first bytes of a file\n")
    _ = records.appendPresentation("  fileSystem.write(at: a.txt, text: \"hi\")   replace what a file says\n")
    _ = records.appendPresentation("  fileSystem.createDirectory(at: docs)       make a folder\n")
    _ = records.appendPresentation("  fileSystem.createFile(at: draft.txt)       make an empty file\n")
    _ = records.appendPresentation("  fileSystem.createContainer(name: app, blocks: 64)\n")
    _ = records.appendPresentation("                                             cut a container out of this one\n")
    _ = records.appendPresentation("  fileSystem.move(from: a.txt, to: b/c.txt)  rename it, or move it\n")
    _ = records.appendPresentation("  fileSystem.remove(at: a.txt)               take it away\n")
    _ = records.appendPresentation("  fileSystem.name(name: laboratorio)        rename the machine\n")
    _ = records.appendPresentation("  fileSystem.compact(at: a.bin)              put a scattered file back in one piece\n")
    _ = records.appendPresentation("  fileSystem.unmount()                       mark the disk clean before stopping\n")
    _ = records.appendPresentation("  fileSystem.scrub()                         read the whole disk and say what is wrong\n")
    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  Parentheses and labels may be left off: fileSystem.read(at: a.txt),\n")
    _ = records.appendPresentation("  read a.txt and fileSystem.read(\"a.txt\") are the same request.\n")
    _ = records.appendPresentation("  a space in it. The receiver may be left off when the verb names\n")
    _ = records.appendPresentation("  only one thing.\n")
    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  A path crosses into a container with :: and walks folders with /,\n")
    _ = records.appendPresentation("  so reix::app::child/doc/x.txt reads as what it is. `..` goes up,\n")
    _ = records.appendPresentation("  and stops at the edge of what this shell was given.\n")
    _ = records.appendPresentation("\n")
    _ = records.appendPresentation("  A spawned program is given the console and the authority to read\n")
    _ = records.appendPresentation("  the process table, and nothing else. It cannot spawn children of\n")
    _ = records.appendPresentation("  its own: the kernel refuses, because this shell does not pass on\n")
    _ = records.appendPresentation("  the capability that would let it.\n")
    _ = records.appendPresentation("\n")
}
