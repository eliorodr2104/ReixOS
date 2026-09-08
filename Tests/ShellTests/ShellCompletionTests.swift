//
//  ShellCompletionTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

private enum CompletionFiles: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("fileSystem", summary: "a container")
    }
    static var commandCount: Int { 6 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        switch index {
            case 0:
                return ShellCommandDescriptor(
                    code     : 0,
                    verb     : "list",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence),
                    schema   : .file,
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
            case 4:
                return ShellCommandDescriptor(
                    code     : 4,
                    verb     : "free",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "free"),
                    summary  : "how much room is left"
                )
            case 5:
                return ShellCommandDescriptor(
                    code     : 5,
                    verb     : "info",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "info", TypedShellParameter("at")),
                    summary  : "what something is, and when"
                )
            default:
                return ShellCommandDescriptor(
                    code     : 3,
                    verb     : "remove",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "remove", TypedShellParameter("at")),
                    sensitive: true,
                    summary  : "take it away"
                )
        }
    }
}

private enum CompletionMachine: ShellCommandProvider {
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

private func offered(
    _ source: String,
      cursor: Int? = nil
) -> (names: [String], kinds: [ShellCompletionKind], truncated: Bool, matched: Int) {
    var catalog = ShellCatalog()
    _ = catalog.merge(CompletionMachine.self)
    _ = catalog.merge(CompletionFiles.self)
    let bytes = Array(source.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return ([], [], false, 0) }
        let snapshot = ShellAnalyzer.analyze(
            base,
            count   : buffer.count,
            cursor  : cursor ?? buffer.count,
            revision: 1,
            catalog : catalog
        )
        let set = ShellCompletionEngine.complete(
            for   : snapshot,
            source: base,
            count : buffer.count,
            catalog: catalog
        )
        var names: [String] = []
        var kinds: [ShellCompletionKind] = []
        for index in 0..<set.count {
            guard let candidate = set.candidate(at: index) else { continue }
            names.append(candidate.withName { bytes, count in
                String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            })
            kinds.append(candidate.kind)
        }
        return (names, kinds, set.truncated, set.matched)
    }
}

@Suite("Shell completion")
struct ShellCompletionTests {

    @Test("At the head of a line, receivers and bare verbs both fit")
    func headOfLine() {
        let all = offered("")
        #expect(all.names.contains("shell"))
        #expect(all.names.contains("fileSystem"))
        #expect(all.names.contains("list"))
        #expect(all.names.contains("let"))
        #expect(all.kinds.contains(.namespace))
        #expect(all.kinds.contains(.keyword))
    }

    @Test("What is typed narrows what is offered")
    func prefixNarrows() {
        let typed = offered("fileS")
        #expect(typed.names == ["fileSystem"])
        #expect(typed.kinds == [.namespace])

        let verb = offered("re")
        #expect(verb.names == ["remove"])
    }

    @Test("After a receiver's dot, only that receiver's verbs")
    func afterReceiver() {
        let commands = offered("fileSystem.")
        #expect(commands.names.contains("list"))
        #expect(commands.names.contains("write"))
        #expect(!commands.names.contains("help"))
        #expect(commands.kinds.allSatisfy { $0 == .command })

        #expect(offered("shell.").names == ["help"])
    }

    @Test("Inside a written call, the labels that command takes")
    func labels() {
        let labels = offered("fileSystem.write(")
        #expect(labels.names == ["at", "text"])
        #expect(labels.kinds == [.label, .label])
    }

    @Test("After a value's dot, what that value is made of")
    func members() {
        let members = offered("list.")
        #expect(members.names.contains("name"))
        #expect(members.names.contains("isFile"))
        #expect(members.names.contains("map"))
        #expect(members.kinds.contains(.member))
        #expect(members.kinds.contains(.method))
    }

    @Test("A name this line gave a value is offered where a value goes")
    func bindings() {
        let bound = offered("let folders = list, changeDir fold")
        #expect(bound.names == ["folders"])
        #expect(bound.kinds == [.variable])
    }

    @Test("The order does not depend on the weather")
    func rankingIsDeterministic() {
        let first  = offered("fileSystem.")
        let second = offered("fileSystem.")
        #expect(first.names == second.names)

        // Shorter first, then alphabetical.
        #expect(first.names == ["free", "info", "list", "write", "remove", "changeDir"])
    }

    @Test("More than fits is counted, not forgotten")
    func boundedList() {
        let all = offered("")
        #expect(all.names.count <= ShellCompletionSet.capacity)
        #expect(all.matched > all.names.count)
        #expect(all.truncated)
    }

    @Test("Where nothing static fits, nothing is offered")
    func nothingToOffer() {
        // An argument's value is a path or a binding; with neither, the static
        // side has nothing to say and does not invent something.
        #expect(offered("changeDir ").names.isEmpty)
    }
}
