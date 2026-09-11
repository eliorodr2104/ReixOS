//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//
//  The catalog and the grammar, against the modules the shell is actually
//  built with. A harness rather than a suite in ShellTests: the shell's
//  modules pull in Reix, whose freestanding stand-ins for `malloc` and
//  `putchar` collide with the kernel's inside one test bundle.
//

import Foundation
import Reix
import ReixABI
import ShellLanguage
@testable import Shell

private func require(
    _ condition: Bool,
    _ what     : String = "",
      file     : StaticString = #fileID,
      line     : UInt = #line
) {
    if !condition {
        fatalError("Shell catalog harness failure at \(file):\(line) \(what)")
    }
}

private func spelling(_ value: StaticString) -> String {
    String(decoding: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount), as: UTF8.self)
}

private func spelled(_ text: ShellText) -> String {
    text.withBytes { bytes, count in
        String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

private struct RecordedCall: Equatable {
    let command  : String
    let arguments: [String]
}

private struct Run {
    var calls  : [RecordedCall] = []
    var failure: TypedShellFailure?
}

/// A receiver that claims a name another provider already holds.
private enum Twin: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("Shell", summary: "a second claim on a taken name")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 0,
            verb     : "help",
            signature: TypedShellSignature(namespace: "Shell", name: "help"),
            summary  : "the same receiver, again"
        )
    }
}

/// A provider filing a command under somebody else's receiver.
private enum Impostor: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("impostor", summary: "declares under a receiver it does not own")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 0,
            verb     : "read",
            signature: TypedShellSignature(namespace: "FileManager", name: "borrowed"),
            summary  : "a command filed under somebody else's receiver"
        )
    }
}

/// A module that arrives later with one live vocabulary. The registry test
/// proves one merge wires both its declaration and its completion hook.
private enum CompletingModule: ShellModule {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("future", summary: "a later module")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 7,
            verb     : "read",
            signature: TypedShellSignature(
                namespace: "future",
                name     : "read",
                TypedShellParameter("at", subject: .path, pathTarget: .file)
            ),
            summary  : "read what this module owns"
        )
    }
    static func handle(_ command: Command, in session: inout ShellSession) -> ShellOutcome {
        .notHandled
    }
    static func complete(
        _ request: ShellModuleCompletionRequest,
          in session: inout ShellSession,
          into offered: inout ShellCompletionSet
    ) {
        guard request.code == 7,
              request.parameter.subject == .path,
              request.parameter.pathTarget == .file,
              let prefix = session.bytes(of: request.context.prefix)
        else { return }
        let name: StaticString = "future.txt"
        guard prefix.count <= name.utf8CodeUnitCount else { return }
        for index in 0..<prefix.count where prefix.bytes[index] != name.utf8Start[index] { return }
        guard let candidate = ShellCompletion(
            kind: .path,
            name: name,
            replacement: request.context.prefix
        ) else { return }
        offered.insert(candidate)
    }
}

/// Runs one source through the catalog the shell resolves against, recording
/// what was invoked instead of carrying it out.
///
/// `refuse` names the call that answers with a service failure, which is how
/// the sequential rule is examined without a disk.
private func run(
    _ source: String,
      refuse: String? = nil
) -> Run {
    var outcome = Run()
    let catalog = ShellPipeline.merged()
    let bytes   = Array(source.utf8)
    bytes.withUnsafeBufferPointer { buffer in
        switch TypedShellParser.parse(
            buffer.baseAddress!,
            count: buffer.count,
            namespaces: catalog.namespaceSet()
        ) {
            case .failure(let failure):
                outcome.failure = failure
            case .success(let program):
                var runtime = TypedShellRuntime()
                var arena   = TypedShellSequenceArena()
                let result  = catalog.withSignatures { signatures in
                    runtime.execute(
                        program,
                        source: buffer.baseAddress!,
                        count: buffer.count,
                        signatures: signatures,
                        arena: &arena
                    ) { invocation in
                        guard let descriptor = catalog.command(at: invocation.signatureIndex) else {
                            return .failure(UInt32.max)
                        }
                        var arguments: [String] = []
                        for index in 0..<invocation.argumentCount {
                            guard case .text(let text)? = invocation.arguments[index]?.value else { continue }
                            arguments.append(spelled(text))
                        }
                        let named = spelling(descriptor.signature.namespace) + "." + spelling(descriptor.signature.name)
                        outcome.calls.append(RecordedCall(command: named, arguments: arguments))
                        return named == refuse ? .failure(7) : .success(.void)
                    }
                }
                if case .failure(let failure) = result { outcome.failure = failure }
        }
    }
    return outcome
}

private func testOneModuleRegistrationWiresLiveCompletion() {
    var modules = ShellModuleRegistry()
    require(modules.merge(CompletingModule.self), "the later module enters the registry")
    let catalog = modules.catalog
    var pipeline = ShellPipeline(
        environment: Environment(console: nil, nameServer: nil, spawn: nil),
        modules: modules
    )
    let source = Array("read fut".utf8)
    source.withUnsafeBufferPointer { bytes in
        let snapshot = ShellAnalyzer.analyze(
            bytes.baseAddress!,
            count   : bytes.count,
            cursor  : bytes.count,
            revision: 1,
            catalog : catalog
        )
        var offered = ShellCompletionSet()
        pipeline.complete(
            for   : snapshot,
            source: bytes.baseAddress!,
            count : bytes.count,
            into  : &offered
        )
        let name = offered.candidate(at: 0)?.withName { candidate, count in
            String(decoding: UnsafeBufferPointer(start: candidate, count: count), as: UTF8.self)
        }
        require(name == "future.txt", "one merge wires a module's live completion")
    }
}

/// Whether the shell's own parser, with the receivers it documented, accepts
/// this source at all.
private func parses(_ source: String) -> Bool {
    let namespaces = ShellPipeline.merged().namespaceSet()
    let bytes      = Array(source.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        if case .success = TypedShellParser.parse(
            buffer.baseAddress!,
            count: buffer.count,
            namespaces: namespaces
        ) { return true }
        return false
    }
}

private func testModulesMerge() {
    let catalog = ShellPipeline.merged()
    require(catalog.namespaceCount == 4, "namespaces merged")
    require(
        catalog.count == CoreModule.commandCount
            + ProcessModule.commandCount
            + DiskModule.commandCount
            + FileSystemModule.commandCount,
        "every module merged whole"
    )

    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index) else { require(false); return }
        // The receiver a command was merged under is the one it declares,
        // which is what dispatch relies on to find its module again.
        require(
            spelling(descriptor.signature.namespace) == catalog.receiver(ofCommandAt: index).map { spelling($0.name) },
            "receiver of \(spelling(descriptor.signature.name))"
        )
    }
    require(catalog.command(at: catalog.count) == nil)
    require(catalog.receiver(ofCommandAt: -1) == nil)
}

private func testMergeRefusesWhatItCannotName() {
    var catalog = ShellCatalog()
    require(catalog.merge(CoreModule.self), "the first provider merges")
    require(!catalog.merge(Twin.self), "a taken receiver is refused")
    require(catalog.namespaceCount == 1)
    require(catalog.count == CoreModule.commandCount)

    require(!catalog.merge(Impostor.self), "a command under another receiver is refused")
    require(catalog.namespaceIndex(named: "impostor") == nil, "and nothing of it is kept")
}

private func testSignatureTableIsTheCatalog() {
    let catalog = ShellPipeline.merged()
    catalog.withSignatures { signatures in
        require(signatures.count == catalog.count)
        for index in signatures.indices {
            guard let signature = signatures[index], let descriptor = catalog.command(at: index) else {
                require(false)
                return
            }
            require(spelling(signature.name) == spelling(descriptor.signature.name))
            require(spelling(signature.namespace) == spelling(descriptor.signature.namespace))
        }
    }
}

private func testSpellingsResolveUniquely() {
    let catalog = ShellPipeline.merged()
    for first in 0..<catalog.count {
        guard let left = catalog.command(at: first) else { continue }
        for second in (first + 1)..<catalog.count {
            guard let right = catalog.command(at: second) else { continue }
            guard spelling(left.signature.name) == spelling(right.signature.name) else { continue }

            require(spelling(left.signature.namespace) != spelling(right.signature.namespace))

            // Two verbs spelled alike may coexist only when writing the
            // receiver is the one way to tell them apart.
            let bothBare  = !left.signature.namespaceRequired && !right.signature.namespaceRequired
            let sameArity = left.signature.parameterCount == right.signature.parameterCount
            require(!(bothBare && sameArity), "\(spelling(left.signature.name)) is ambiguous without a receiver")
        }
    }
}

private func testEveryCommandNamesItsAuthority() {
    let catalog = ShellPipeline.merged()
    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index) else { continue }
        let name = spelling(descriptor.signature.name)
        // The shell's own three need no authority: they are about the shell.
        if name == "help" || name == "exit" || name == "clear" { continue }
        require(descriptor.capability != nil, "\(name) claims no capability")
    }
}

private func testObjectsCarryASchema() {
    let catalog = ShellPipeline.merged()
    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index) else { continue }
        if descriptor.signature.result == .sequence || descriptor.signature.result == .record {
            require(descriptor.schema != .none, "\(spelling(descriptor.signature.name)) answers with unnamed objects")
            require(ShellCatalog.memberCount(of: descriptor.schema) > 0)
        }
    }
    require(ShellCatalog.member(of: .entry, at: 0) != nil)
    require(ShellCatalog.member(of: .entry, at: ShellCatalog.memberCount(of: .entry)) == nil)
}

private func testSpellingsAreEquivalent() {
    let expected = [RecordedCall(command: "FileManager.changeDir", arguments: ["vault"])]
    for source in [
        "FileManager.changeDir vault",
        "FileManager.changeDir(at: \"vault\")",
        "changeDir vault",
        "changeDir(at: \"vault\")",
    ] {
        let outcome = run(source)
        require(outcome.failure == nil, "refused: \(source)")
        require(outcome.calls == expected, "\(source) did not resolve like the others")
    }
}

private func testLabelsAndOrderAgree() {
    let expected = [RecordedCall(command: "FileManager.move", arguments: ["draft", "archive"])]
    for source in [
        "FileManager.move(from: \"draft\", to: \"archive\")",
        "FileManager.move(to: \"archive\", from: \"draft\")",
        "move from draft to archive",
        "move draft archive",
    ] {
        let outcome = run(source)
        require(outcome.failure == nil, "refused: \(source)")
        require(outcome.calls == expected, "\(source) did not place its arguments like the others")
    }
}

private func testCommaIsSequentialAndFailsClosed() {
    let carried = run("FileManager.currentDirectory(), FileManager.free(), FileManager.scrub()")
    require(carried.failure == nil)
    require(carried.calls.map(\.command) == [
        "FileManager.currentDirectory",
        "FileManager.free",
        "FileManager.scrub",
    ])

    let stopped = run(
        "FileManager.currentDirectory(), FileManager.free(), FileManager.scrub()",
        refuse: "FileManager.free"
    )
    require(stopped.failure == .service(7))
    require(stopped.calls.map(\.command) == ["FileManager.currentDirectory", "FileManager.free"])
}

private func testOmissionNeedsAUniqueAnswer() {
    require(run("list").calls.map(\.command) == ["FileManager.list"])
    require(run("ProcessManager.list").calls.map(\.command) == ["ProcessManager.list"])

    // `read` is spelled by two receivers. The bare form belongs to the one
    // that does not insist on being named.
    require(run("read a.txt").calls == [RecordedCall(command: "FileManager.read", arguments: ["a.txt"])])
    require(run("Disk.read 0").calls.map(\.command) == ["Disk.read"])

    let unknown = run("readd a.txt")
    require(unknown.calls.isEmpty)
    guard case .unknownSymbol(let name)? = unknown.failure else {
        require(false, "an unknown verb was not refused as unknown")
        return
    }
    require(spelled(name) == "readd")
}

private func testAmbiguityIsRefused() {
    var signatures = InlineArray<2, TypedShellSignature?>(repeating: nil)
    signatures[0] = TypedShellSignature(namespace: "left", name: "sync")
    signatures[1] = TypedShellSignature(namespace: "right", name: "sync")
    let bytes = Array("sync".utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard case .success(let program) = TypedShellParser.parse(
            buffer.baseAddress!,
            count: buffer.count
        ) else {
            require(false, "sync did not parse")
            return
        }
        var runtime = TypedShellRuntime()
        var arena   = TypedShellSequenceArena()
        var invoked = 0
        let result  = signatures.span.withUnsafeBufferPointer { table in
            runtime.execute(
                program,
                source: buffer.baseAddress!,
                count: buffer.count,
                signatures: table,
                arena: &arena
            ) { _ in
                invoked += 1
                return .success(.void)
            }
        }
        require(invoked == 0, "an ambiguous verb was carried out")
        guard case .failure(.ambiguousCall(let name, let count)) = result else {
            require(false, "an ambiguous verb was resolved anyway")
            return
        }
        require(spelled(name) == "sync")
        require(count == 2)
    }
}

private func testQuotesMayBeLeftOffOneWord() {
    require(run("write draft \"two words\"").calls == [
        RecordedCall(command: "FileManager.write", arguments: ["draft", "two words"]),
    ])

    // Without them the phrase is a third argument, and a command that takes
    // two is refused rather than shortened to fit.
    let split = run("write draft two words")
    require(split.calls.isEmpty)
    require(split.failure != nil)
}

/// The written form of a compact call has to mean the same thing, which is
/// what the help has always claimed and what the live shell refused.
private func testWrittenArgumentsMayBeBareWords() {
    require(run("FileManager.createDirectory(at: vault)").calls == [
        RecordedCall(command: "FileManager.createDirectory", arguments: ["vault"]),
    ])
    require(run("FileManager.changeDir(at: reix::app/doc)").calls == [
        RecordedCall(command: "FileManager.changeDir", arguments: ["reix::app/doc"]),
    ])
    require(run("info(at: a.txt)").calls == [
        RecordedCall(command: "FileManager.info", arguments: ["a.txt"]),
    ])

    // The word rule is for arguments, not for the verb: a misspelled command
    // is still nothing this shell knows.
    let unknown = run("readd(at: a.txt)")
    require(unknown.calls.isEmpty)
    require(unknown.failure != nil)

    // `$0` outside a closure is a name the evaluator owes, not a word.
    let orphan = run("FileManager.read(at: $0)")
    require(orphan.calls.isEmpty)
    guard case .unknownSymbol? = orphan.failure else {
        require(false, "an unsupplied $0 became its own spelling")
        return
    }
}

/// A closure may name what it is handed, and the name is a value for as long
/// as its body runs.
private func testClosuresMayNameTheirElement() {
    require(parses("list.filter { entry in entry.isFolder }"), "a named closure parameter parses")
    require(parses("list.sorted { left in left.name }"), "and so does one on sorted")
    require(parses("list.filter { $0.isFolder }"), "the short form still works")

    // `in` is what makes it a parameter. Without it, it is an expression.
    require(parses("list.filter { $0.name.contains(\"a\") }"), "a body that is not a name")

    let named = run("list.filter { entry in entry.isFolder }")
    require(named.failure == nil || named.calls.count == 1, "it reaches the service, whatever the disk says")
}

/// The receiver rule must not swallow the member chains the language already
/// had. A verb is not a receiver, and a value named like one is still a value.
private func testReachingIntoValuesStillReads() {
    require(parses("list.filter { $0.isFolder }"), "a bare verb still takes a method")
    require(parses("FileManager.list().filter { $0.name.contains(\"a\") }"), "a written call still chains")
    require(parses("FileManager.list.filter { $0.isFolder }"), "a receiver, its verb, and a method")
    require(parses("let folders = list\n    .filter { $0.isFolder }"), "a chain continued on the next line")
    require(parses("let FileManager = list, FileManager.filter { $0.isFolder }"), "a binding named like a receiver")
    require(parses("list.map { $0.name }.compactMap { $0 }"), "two methods in a row")

    // Parentheses do not make a receiver: `list.reversed()` is a method on
    // what `list` answers with, and was being read as a call to a receiver
    // called `list`.
    let reversed = run("list.reversed()")
    require(reversed.calls.map(\.command) == ["FileManager.list"], "the list is asked for")
    guard case .type? = reversed.failure else {
        require(reversed.failure == nil, "reversed is a method, not a symbol: \(String(describing: reversed.failure))")
        return
    }
}

/// What the editor costs to hold, which is a thing worth knowing before a
/// terminal finds out for you.
///
/// The catalog was once carried by value inside the editor, which made an
/// editor eleven kilobytes and a test that holds six of them a stack
/// overflow. These ceilings are stated so the next such change is a failing
/// check rather than a crash.
private func testNothingOnTheStackIsEnormous() {
    require(MemoryLayout<ShellCatalog>.size <= 1024, "the catalog indexes its providers, it does not copy them")
    require(MemoryLayout<ShellLineEditor>.size <= 6144, "one editor stays inside six kilobytes")
    require(MemoryLayout<ShellAnalysisSnapshot>.size <= 1024, "one reading of a revision stays inside a kilobyte")
    require(MemoryLayout<ShellTokenStream>.size <= 2048, "and so does the token stream, twice over")
}

/// Help is generated now, not written out, so what it says is worth asking.
private func testHelpSaysWhatThisShellHolds() {
    let catalog = ShellPipeline.merged()

    func helpText(_ asked: String) -> String {
        let line = Array(asked.utf8)
        return line.withUnsafeBufferPointer { bytes in
            var session = ShellSession(
                environment: Environment(console: 1, nameServer: 2, spawn: 3),
                line       : bytes.baseAddress ?? UnsafePointer(bitPattern: 1)!,
                count      : bytes.count,
                catalog    : catalog
            )
            var command = Command(receiver: Span(start: 0, count: 0), verb: Span(start: 0, count: 0))
            if !asked.isEmpty {
                command.arguments[0] = Span(start: 0, count: bytes.count)
                command.argumentCount = 1
            }
            let result = CoreModule.help(command, in: &session)
            var text = ""
            for index in 0..<result.count {
                guard let record = result.record(at: index), record.kind == .presentation else { continue }
                var storage = record.text
                text += storage.span.withUnsafeBufferPointer {
                    String(decoding: UnsafeBufferPointer(start: $0.baseAddress!, count: record.textCount), as: UTF8.self)
                }
            }
            return text
        }
    }

    let overview = helpText("")
    require(overview.contains("ReixOS shell"), "it says what it is")
    require(overview.contains("Shell"), "and names the receiver it always has")
    // This environment holds no container, no profiler and no block, so the
    // three receivers that need them are listed as withheld.
    require(overview.contains("It was given no authority for:"), "and says what it cannot do")
    require(overview.contains("FileManager"), "naming the receiver it cannot use")

    let receiver = helpText("FileManager")
    require(receiver.contains("changeDir"), "a receiver's help lists its commands")
    require(receiver.contains("no authority"), "and says when none of them would run")

    let command = helpText("read")
    require(command.contains("FileManager.read"), "a command's help names it in full")
    require(command.contains("answers"), "and says what it answers with")

    require(helpText("nonsense").contains("no receiver and no command"), "and says so when nothing answers")
}

/// What the shell would offer at the cursor, against its own receivers.
private func testCompletionOffersWhatTheShellHas() {
    let catalog = ShellPipeline.merged()

    func offered(_ source: String) -> [String] {
        let bytes = Array(source.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            let snapshot = ShellAnalyzer.analyze(
                buffer.baseAddress!,
                count   : buffer.count,
                cursor  : buffer.count,
                revision: 1,
                catalog : catalog
            )
            let set = ShellCompletionEngine.complete(
                for    : snapshot,
                source : buffer.baseAddress!,
                count  : buffer.count,
                catalog: catalog
            )
            var names: [String] = []
            for index in 0..<set.count {
                guard let candidate = set.candidate(at: index) else { continue }
                names.append(candidate.withName { bytes, count in
                    String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
                })
            }
            return names
        }
    }

    let head = offered("")
    require(head.contains("FileManager"), "a receiver is offered at the head of a line")
    require(head.contains("Shell"), "and so is the other one")

    let verbs = offered("FileManager.c")
    require(verbs.contains("compact"), "a receiver's verbs are offered after its dot")
    require(verbs.contains("createFile"), "including the longer ones")
    require(!verbs.contains("read"), "and only the ones that begin with what was typed")

    let labels = offered("FileManager.write(")
    require(labels == ["at", "text"], "a command's labels, in the order it takes them")

    // `list` answers with `[Entry]`, so what it offers is what a list offers.
    let listing = offered("list.")
    require(listing.contains("count"), "a list knows how many it holds")
    require(listing.contains("filter"), "and what can be done to it")
    require(!listing.contains("isFolder"), "but not what its elements are")

    // The same for every receiver, not only the file manager: a process list
    // is a list of processes and one of them is a process.
    let processes = offered("ProcessManager.list().filter { $0.")
    require(processes.contains("name"), "a process has a name")
    require(processes.contains("id"), "and the number the kernel knows it by")
    require(!processes.contains("isFolder"), "and nothing that belongs to an entry")

    let nested = offered("list.filter { $0.name.")
    require(nested.contains("hasPrefix"), "a name is a text, two dots deep")

    // A closure inside a closure reads like the first one, and closing the
    // inner one gives the outer element back.
    let inner = offered("list.filter { $0.name.contains(\"a\") }.map { $0.")
    require(inner.contains("isFolder"), "the outer element is an entry again")

    // One of them, inside a closure over it, is a file.
    let element = offered("list.filter { $0.")
    require(element.contains("isFolder"), "an element of a listing is an entry")
    require(element.contains("name"), "and entries have names")

    // `disk.read` insists on its receiver, so the bare `read` on offer is the
    // file system's and there is only one of it.
    let bare = offered("read")
    require(bare == ["read"], "one bare read, the one that answers without a receiver")
}

/// Every role the shell can emit has to mean something to the backend, in
/// both profiles. A role nobody painted would be an invisible token.
private func testEveryRoleHasAColour() {
    let roles: [ReixTextSurfaceStyleRole] = [
        .plain, .prompt, .input, .selection, .diagnostic, .overlay, .editorChrome,
        .keyword, .namespace, .command, .label, .text, .number, .path,
        .variable, .member, .closure, .incomplete, .error,
    ]
    for profile in [ReixTerminalColorProfile.indexed256, .ansi16] {
        TextSurfacePalette.profile = profile
        for role in roles {
            // Plain adds nothing to the reset the renderer already emits.
            guard role != .plain, role != .input else { continue }
            require(TextSurfacePalette.parameters(for: role).utf8CodeUnitCount > 0, "a role with no colour")
        }
        // The distinctions the eye is meant to make.
        let namespace = spelling(TextSurfacePalette.parameters(for: .namespace))
        let command   = spelling(TextSurfacePalette.parameters(for: .command))
        let text      = spelling(TextSurfacePalette.parameters(for: .text))
        let error     = spelling(TextSurfacePalette.parameters(for: .error))
        require(namespace != command, "a receiver looks like its verb")
        require(command != text, "a verb looks like a string")
        require(error != command, "a mistake looks like a verb")
    }
    TextSurfacePalette.profile = .indexed256
    require(spelling(TextSurfacePalette.parameters(for: .command)) == "38;5;214", "gruvbox yellow for a verb")
}

/// The analysis, against the receivers the shell is actually built with.
private func testAnalysisReadsTheRealCatalog() {
    let catalog = ShellPipeline.merged()

    func snapshot(_ source: String, cursor: Int? = nil) -> ShellAnalysisSnapshot {
        let bytes = Array(source.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            ShellAnalyzer.analyze(
                buffer.baseAddress!,
                count   : buffer.count,
                cursor  : cursor ?? buffer.count,
                revision: 1,
                catalog : catalog
            )
        }
    }

    // FileManager.changeDir(at: reix::vault)
    // 0          12         23  27
    let written = snapshot("FileManager.changeDir(at: reix::vault)")
    require(written.role(at: 0) == .namespace, "FileManager is a receiver")
    require(written.role(at: 12) == .command, "changeDir is its command")
    require(written.role(at: 22) == .label, "at is a label it takes")
    require(written.role(at: 26) == .path, "reix::vault is a path")
    require(written.diagnosticCount == 0, "nothing to report about a good line")

    // The receivers only this shell has, resolved through the merged catalog.
    let processes = snapshot("ProcessManager.")
    require(processes.context.subject == .command, "after a receiver, its commands")
    require(processes.context.receiver >= 0, "and the receiver is named")

    let disk = snapshot("Disk.read 0")
    require(disk.role(at: 5) == .command, "read belongs to disk when disk is written")
    require(disk.role(at: 10) == .number, "a sector is a number")

    let typo = snapshot("FileManager.chagne ")
    require(typo.role(at: 12) == .error, "a finished name nobody answers to is wrong")
    require(typo.diagnosticCount == 1, "and it is reported once")
}

testModulesMerge()
testMergeRefusesWhatItCannotName()
testAnalysisReadsTheRealCatalog()
testEveryRoleHasAColour()
testNothingOnTheStackIsEnormous()
testCompletionOffersWhatTheShellHas()
testHelpSaysWhatThisShellHolds()
testSignatureTableIsTheCatalog()
testSpellingsResolveUniquely()
testEveryCommandNamesItsAuthority()
testObjectsCarryASchema()
testSpellingsAreEquivalent()
testLabelsAndOrderAgree()
testCommaIsSequentialAndFailsClosed()
testOmissionNeedsAUniqueAnswer()
testAmbiguityIsRefused()
testQuotesMayBeLeftOffOneWord()
testReachingIntoValuesStillReads()
testClosuresMayNameTheirElement()
testWrittenArgumentsMayBeBareWords()
testOneModuleRegistrationWiresLiveCompletion()

// `print` would reach Reix's freestanding `putchar`, which has no console
// here. The harness says how it went through the file descriptor instead.
FileHandle.standardOutput.write(Data("ShellCatalogHarness: 21 checks passed\n".utf8))
