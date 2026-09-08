//
//  ShellAnalyzerTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

/// Two receivers, documented the way a module documents itself, so the
/// analysis is examined against a catalog and not against a hard-coded list.
private enum FilesProvider: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("fileSystem", summary: "a container")
    }
    static var commandCount: Int { 3 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        switch index {
            case 0:
                return ShellCommandDescriptor(
                    code     : 0,
                    verb     : "list",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence),
                    schema   : .files,
                    summary  : "what is here"
                )
            case 1:
                return ShellCommandDescriptor(
                    code     : 1,
                    verb     : "move",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "changeDir", TypedShellParameter("at")),
                    summary  : "change this session's directory"
                )
            case 2:
                return ShellCommandDescriptor(
                    code     : 2,
                    verb     : "write",
                    signature: TypedShellSignature(
                        namespace: "fileSystem",
                        name     : "write",
                        TypedShellParameter("at"),
                        TypedShellParameter("text")
                    ),
                    sensitive: true,
                    summary  : "replace what a file says"
                )
            default:
                return nil
        }
    }
}

private enum MachineProvider: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("shell", summary: "this shell itself")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 0,
            verb     : "help",
            signature: TypedShellSignature(namespace: "shell", name: "help", effect: .pure),
            summary  : "what this shell understands"
        )
    }
}

private func catalog() -> ShellCatalog {
    var catalog = ShellCatalog()
    _ = catalog.merge(MachineProvider.self)
    _ = catalog.merge(FilesProvider.self)
    return catalog
}

private func analyze(
    _ source: String,
      cursor: Int? = nil,
      revision: UInt32 = 1
) -> ShellAnalysisSnapshot {
    let bytes = Array(source.utf8)
    let table = catalog()
    return bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return ShellAnalysisSnapshot(revision: revision) }
        return ShellAnalyzer.analyze(
            base,
            count   : buffer.count,
            cursor  : cursor ?? buffer.count,
            revision: revision,
            catalog : table
        )
    }
}

/// The role covering the first byte of `needle`.
private func role(
    _ snapshot: ShellAnalysisSnapshot,
    _ source  : String,
      of needle: String
) -> ShellSemanticRole {
    guard let range = source.range(of: needle) else { return .plain }
    return snapshot.role(at: source.utf8.distance(from: source.utf8.startIndex, to: range.lowerBound.samePosition(in: source.utf8)!))
}

private func diagnostics(_ snapshot: ShellAnalysisSnapshot) -> [ShellDiagnosticKind] {
    (0..<snapshot.diagnosticCount).compactMap { snapshot.diagnostic(at: $0)?.kind }
}

@Suite("Shell analysis")
struct ShellAnalyzerTests {

    @Test("A written call is a receiver, a command, a label and a text")
    func writtenCallRoles() {
        let source   = "fileSystem.changeDir(at: \"vault\")"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "fileSystem") == .namespace)
        #expect(role(snapshot, source, of: "changeDir") == .command)
        #expect(role(snapshot, source, of: "at") == .label)
        #expect(role(snapshot, source, of: "\"vault\"") == .text)
        #expect(diagnostics(snapshot).isEmpty)
    }

    @Test("A compact call is the same command, and its argument is a word")
    func compactCallRoles() {
        let source   = "changeDir vault"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "changeDir") == .command)
        #expect(role(snapshot, source, of: "vault") == .plain)
        #expect(diagnostics(snapshot).isEmpty)
    }

    @Test("A path and a number are what they are, wherever they sit")
    func valueRoles() {
        let source   = "changeDir reix::app/doc"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "reix::app/doc") == .path)
    }

    @Test("A name nobody answers to is wrong, unless it is still being typed")
    func unknownNames() {
        let typo = analyze("fileSystem.chagneDir vault")
        #expect(role(typo, "fileSystem.chagneDir vault", of: "chagneDir") == .error)
        #expect(diagnostics(typo) == [.unknownCommand])

        // The same bytes with the cursor at the end of them are a prefix.
        let typing = analyze("fileSystem.chan")
        #expect(role(typing, "fileSystem.chan", of: "chan") == .incomplete)
        #expect(diagnostics(typing).isEmpty)
    }

    @Test("A label the command does not take is placed where it stands")
    func unknownLabel() {
        let source   = "fileSystem.write(when: \"now\")"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "when") == .error)
        #expect(diagnostics(snapshot) == [.unknownLabel])
    }

    @Test("A dotted word in an argument is one word, not a member of something")
    func dottedWordsInArguments() {
        let source   = "fileSystem.write(at: memo.txt, text: \"hi\")"
        let snapshot = analyze(source)
        // `memo` and `txt` are the same name to the evaluator, so neither is
        // painted as reaching into a value.
        #expect(role(snapshot, source, of: "memo") == .plain)
        #expect(role(snapshot, source, of: "txt") == .plain)
        #expect(diagnostics(snapshot).isEmpty)

        // A closure expression has members too.
        let placeholder = analyze("list.filter { $0.isFolder }")
        #expect(role(placeholder, "list.filter { $0.isFolder }", of: "isFolder") == .member)
    }

    @Test("A member is read against what the value is")
    func memberRoles() {
        let source   = "list.filter { $0.isFolder }"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "list") == .command)
        #expect(role(snapshot, source, of: "filter") == .member)
        #expect(role(snapshot, source, of: "{") == .closure)
        #expect(role(snapshot, source, of: "$0") == .variable)
        #expect(role(snapshot, source, of: "isFolder") == .member)
        #expect(diagnostics(snapshot).isEmpty)

        // A list is not what is in it: `isFolder` belongs to a file.
        let onTheList = analyze("list.isFolder ")
        #expect(role(onTheList, "list.isFolder ", of: "isFolder") == .error)

        // Finished, so it is wrong rather than half typed.
        let wrong = analyze("list.isPurple ")
        #expect(role(wrong, "list.isPurple ", of: "isPurple") == .error)
        #expect(diagnostics(wrong) == [.unknownMember])
    }

    @Test("A closure may name what it is given")
    func namedClosureParameter() {
        let source   = "list.filter { entry in entry.isFolder }"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "entry in") == .variable)
        #expect(role(snapshot, source, of: "in entry") == .keyword)
        #expect(role(snapshot, source, of: "isFolder") == .member)
        #expect(diagnostics(snapshot).isEmpty)

        // The name stands for one element, so reaching into it offers a file.
        let reaching = analyze("list.filter { entry in entry.")
        #expect(reaching.context.subject == .member)
        #expect(reaching.context.schema == .file)
    }

    @Test("A binding is a value everywhere it is used")
    func bindings() {
        let source   = "let folders = list, folders.filter { $0.isFile }"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "let") == .keyword)
        #expect(role(snapshot, source, of: "folders =") == .variable)
        #expect(diagnostics(snapshot).isEmpty)
    }

    @Test("A quote nobody closed is unfinished, and the line before it keeps its meaning")
    func unterminatedText() {
        let source   = "fileSystem.write(at: memo, text: \"still"
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "fileSystem") == .namespace)
        #expect(role(snapshot, source, of: "write") == .command)
        #expect(role(snapshot, source, of: "\"still") == .incomplete)
        #expect(diagnostics(snapshot) == [.unterminatedText])
        #expect(snapshot.completeness == .incomplete(indent: 1))
    }

    @Test("A byte that begins nothing is placed and the reading goes on")
    func invalidBytes() {
        let source   = "list ??? "
        let snapshot = analyze(source)
        #expect(role(snapshot, source, of: "list") == .command)
        #expect(role(snapshot, source, of: "?") == .error)
        #expect(diagnostics(snapshot) == [.invalidByte, .invalidByte, .invalidByte])
    }

    @Test("What fits at the cursor is decided where the language was read")
    func completionContext() {
        #expect(analyze("").context.subject == .receiverOrCommand)

        let head = analyze("fileSy")
        #expect(head.context.subject == .receiverOrCommand)
        #expect(head.context.count == 6)

        // After a receiver's dot, only that receiver's commands fit.
        let afterDot = analyze("fileSystem.")
        #expect(afterDot.context.subject == .command)
        #expect(afterDot.context.receiver >= 0)
        #expect(afterDot.context.count == 0)

        let partial = analyze("fileSystem.chan")
        #expect(partial.context.subject == .command)
        #expect(partial.context.count == 4)

        // Inside a written call, an argument begins with a label.
        #expect(analyze("fileSystem.write(").context.subject == .label)

        // A command with its arguments open wants values, of the type it says.
        let value = analyze("changeDir ")
        #expect(value.context.subject == .value)
        #expect(value.context.expected == .text)

        // Reaching into a value offers what that value is.
        let member = analyze("list.")
        #expect(member.context.subject == .member)
        #expect(member.context.schema == .files)

        // And inside a closure over it, one of them.
        let element = analyze("list.filter { $0.")
        #expect(element.context.subject == .member)
        #expect(element.context.schema == .file)

        // Inside the verb itself, what fits is another verb, and one byte
        // further along it is that verb's first argument.
        let insideVerb = analyze("changeDir vault", cursor: 5)
        #expect(insideVerb.context.subject == .receiverOrCommand)
        #expect(insideVerb.context.count == 9)

        let atArgument = analyze("changeDir vault", cursor: 13)
        #expect(atArgument.context.subject == .value)
        #expect(atArgument.context.count == 5)
    }

    @Test("A snapshot says which revision it is about")
    func generationFence() {
        let snapshot = analyze("list", revision: 7)
        #expect(snapshot.fences(7))
        #expect(!snapshot.fences(8))
        #expect(!snapshot.fences(6))
    }
}
