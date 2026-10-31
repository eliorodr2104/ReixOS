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
                    schema   : .entries,
                    summary  : "what is here"
                )
            case 1:
                return ShellCommandDescriptor(
                    code     : 1,
                    verb     : "move",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "changeDir", TypedShellParameter("at", subject: .path, pathTarget: .place)),
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
            signature: TypedShellSignature(
                namespace: "shell",
                name     : "help",
                TypedShellParameter("of", subject: .symbol, required: false),
                effect   : .pure
            ),
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

private func detail(
    of name: String,
    in source: String
) -> String? {
    var catalog = ShellCatalog()
    _ = catalog.merge(CompletionMachine.self)
    _ = catalog.merge(CompletionFiles.self)
    let bytes = Array(source.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return nil }
        let snapshot = ShellAnalyzer.analyze(
            base, count: buffer.count, cursor: buffer.count, revision: 1, catalog: catalog
        )
        let set = ShellCompletionEngine.complete(
            for: snapshot, source: base, count: buffer.count, catalog: catalog
        )
        for index in 0..<set.count {
            guard let candidate = set.candidate(at: index) else { continue }
            let candidateName = candidate.withName { nameBytes, count in
                String(decoding: UnsafeBufferPointer(start: nameBytes, count: count), as: UTF8.self)
            }
            guard candidateName == name else { continue }
            return String(decoding: UnsafeBufferPointer(
                start: candidate.detail.utf8Start,
                count: candidate.detail.utf8CodeUnitCount
            ), as: UTF8.self)
        }
        return nil
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

    @Test("A list answers about the list, and its elements about themselves")
    func members() {
        // `list` is `[File]`. What it answers to is what a list answers to.
        let list = offered("list.")
        #expect(list.names.contains("count"))
        #expect(list.names.contains("isEmpty"))
        #expect(list.names.contains("first"))
        #expect(list.names.contains("filter"))
        #expect(!list.names.contains("isFolder"), "that belongs to what is in it")
        #expect(list.kinds.contains(.member))
        #expect(list.kinds.contains(.method))

        // Inside a closure over it, `$0` is one file.
        let element = offered("list.filter { $0.")
        #expect(element.names.contains("isFolder"))
        #expect(element.names.contains("name"))
        #expect(!element.names.contains("count"))

        // And reaching through a member keeps the type: the first of a list of
        // files is a file.
        #expect(offered("list.first.").names.contains("isFolder"))
    }

    @Test("A closure offers complete expressions before its placeholder is written")
    func closureScope() {
        let filtered = offered("list.filter { ")
        #expect(filtered.names.contains("$0.isFolder"))
        #expect(filtered.names.contains("$0.isContainer"))
        #expect(filtered.names.contains("$0.isFile"))
        #expect(!filtered.names.contains("$0.count"), "the scope is one entry, not its list")

        let narrowed = offered("list.filter { $")
        #expect(narrowed.names.contains("$0.isFolder"))
        #expect(narrowed.names.allSatisfy { $0.hasPrefix("$") })

        let sorted = offered("list.sorted { ")
        #expect(sorted.names.contains("$0.name"))
        #expect(sorted.names.contains("$1.name"), "a two-element closure exposes its second value too")

        let named = offered("list.filter { file in ")
        #expect(named.names.contains("file.isFile"))
        #expect(!named.names.contains("$0.isFile"), "the closure uses the name it declared")

        let multiline = offered("list.filter {\n    ")
        #expect(multiline.names.contains("$0.isFile"), "editor-mode newlines preserve closure scope")
        #expect(multiline.names.contains("true"))
        #expect(multiline.names.contains("false"))
    }

    @Test("A name this line gave a value is offered where a value goes")
    func bindings() {
        let bound = offered("let folders = list, changeDir fold")
        #expect(bound.names == ["folders"])
        #expect(bound.kinds == [.variable])

        #expect(detail(of: "folders", in: "let folders = list, folders") == "[Entry]")
        #expect(detail(of: "greeting", in: "let greeting = \"hello\", greeting") == "String")
        #expect(offered("let greeting = \"hello\", greeting.").names.contains("uppercased"))

        let outside = offered("list.filter { file in file.isFile }, changeDir fi")
        #expect(!outside.names.contains("file"), "a closure parameter is not visible after its brace")
    }

    @Test("Bool operators complete in expressions and String methods show Swift types")
    func typedExpressions() {
        let halfAnd = offered("list.filter { $0.isFolder &")
        #expect(halfAnd.names == ["&&"])
        #expect(halfAnd.kinds == [.operatorSymbol])

        let afterBool = offered("list.filter { $0.isFolder ")
        #expect(afterBool.names.contains("&&"))
        #expect(afterBool.names.contains("||"))

        let continued = offered("true &&\n    f")
        #expect(continued.names == ["false"])

        let strings = offered("\"hello\".")
        #expect(strings.names.contains("appending"))
        #expect(strings.names.contains("lowercased"))
        #expect(strings.names.contains("uppercased"))
        #expect(strings.names.contains("trimmed"))
        #expect(detail(of: "appending", in: "\"hello\".") == "(String) -> String")
        #expect(detail(of: "lowercased", in: "\"hello\".") == "() -> String")
    }

    @Test("A member site cannot be polluted by literals or module candidates")
    func memberKindFence() {
        for source in [
            "let value = \"hello\", value.",
            "let value = 42, value.",
            "let value = true, value.",
            "list.",
            "list.first.",
            "list.filter { $0."
        ] {
            let result = offered(source)
            #expect(!result.names.contains("true"), "\(source) must remain a typed member query")
            #expect(!result.names.contains("false"), "\(source) must remain a typed member query")
            #expect(result.kinds.allSatisfy { $0 == .member || $0 == .method })
        }

        // The same fence is retained when a module receives the set and adds
        // live candidates. This is the generic boundary future modules use.
        var moduleSet = ShellCompletionSet(subject: .member)
        moduleSet.insert(ShellCompletion(kind: .keyword, name: "true")!)
        moduleSet.insert(ShellCompletion(kind: .path, name: "memo.txt")!)
        moduleSet.insert(ShellCompletion(kind: .method, name: "uppercased")!)
        #expect(moduleSet.count == 1)
        #expect(moduleSet.candidate(at: 0)?.kind == .method)
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
        #expect(all.matched == all.names.count, "this catalog fits inside the bound")

        // The bound itself, without needing a catalog large enough to reach it.
        var set = ShellCompletionSet()
        for index in 0..<(ShellCompletionSet.capacity + 4) {
            let name: StaticString = index % 2 == 0 ? "alpha" : "beta"
            set.insert(ShellCompletion(kind: .command, name: name)!)
        }
        #expect(set.count == ShellCompletionSet.capacity)
        #expect(set.matched == ShellCompletionSet.capacity + 4)
        #expect(set.truncated)

        var boundedLive = ShellCompletionSet()
        boundedLive.insert(ShellCompletion(kind: .path, name: "one")!)
        boundedLive.markIncomplete()
        #expect(boundedLive.matched == 1, "unknown live rows are not invented as matches")
        #expect(boundedLive.omitted == 1, "the popup still says at least one row was not scanned")
        #expect(boundedLive.truncated)
    }

    @Test("A parameter that names something is offered that something")
    func symbolArguments() {
        // `help` takes the name of a receiver or a command, so that is what is
        // offered where its argument goes.
        let asked = offered("help fileS")
        #expect(asked.names == ["fileSystem"])

        let all = offered("help ")
        #expect(all.names.contains("fileSystem"))
        #expect(all.names.contains("list"))
    }

    @Test("Where nothing static fits, nothing is offered")
    func nothingToOffer() {
        // An argument's value is a path or a binding; with neither, the static
        // side has nothing to say and does not invent something.
        #expect(offered("changeDir ").names.isEmpty)
    }
}
