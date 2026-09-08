//
//  ShellGhostTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

/// A receiver nobody has heard of, merged the way a module added later would
/// be. Nothing about the grey word is written down per command.
private enum LatecomerModule: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("pluto", summary: "a receiver added later")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 0,
            verb     : "pippo",
            signature: TypedShellSignature(namespace: "pluto", name: "pippo"),
            summary  : "whatever a module wants"
        )
    }
}

private enum GhostFiles: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("fileSystem", summary: "a container")
    }
    static var commandCount: Int { 2 }
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
            default:
                return ShellCommandDescriptor(
                    code     : 1,
                    verb     : "move",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "changeDir", TypedShellParameter("at")),
                    summary  : "change this session's directory"
                )
        }
    }
}

private func editor(withLatecomer latecomer: Bool = false) -> ShellLineEditor {
    var catalog = ShellCatalog()
    _ = catalog.merge(GhostFiles.self)
    if latecomer { _ = catalog.merge(LatecomerModule.self) }
    return ShellLineEditor(catalog: catalog)
}

private func type(
    _ text: String,
      into editor: inout ShellLineEditor,
      sequence: inout UInt32
) {
    for byte in Array(text.utf8) {
        var payload = byte
        let record = withUnsafePointer(to: &payload) {
            ReixInputRecord(kind: .insert, sequence: sequence, bytes: $0, count: 1)!
        }
        _ = editor.apply(record)
        sequence += 1
    }
}

private func tab(
    into editor: inout ShellLineEditor,
    sequence: inout UInt32
) -> ShellEditorUpdate {
    let record = ReixInputRecord(
        kind       : .key,
        sequence   : sequence,
        logicalKey : .tab,
        physicalKey: 0x8000 | ReixInputKey.tab.rawValue
    )!
    sequence += 1
    return editor.apply(record)
}

private func line(_ editor: inout ShellLineEditor) -> String {
    editor.withBytes { bytes, count in
        String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

/// What is drawn beside the line without being in it.
private func ghost(_ editor: inout ShellLineEditor) -> (text: String, role: ReixTextSurfaceStyleRole?) {
    var text = ""
    var role : ReixTextSurfaceStyleRole?
    _ = editor.withFrame { source in
        guard let overlay = source.overlay, source.overlayLength > 0 else { return true }
        text = String(decoding: UnsafeBufferPointer(start: overlay, count: source.overlayLength), as: UTF8.self)
        if source.overlayStyleCount > 0 { role = source.overlayStyles![0].role }
        return true
    }
    return (text, role)
}

@Suite("Shell ghost text")
struct ShellGhostTests {

    @Test("One letter is enough to be shown the rest of the word")
    func ghostsAKeyword() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("l", into: &subject, sequence: &sequence)

        let shown = ghost(&subject)
        #expect(shown.text == "et")
        #expect(shown.role == .ghost)
        #expect(line(&subject) == "l", "the grey word is not in the line")
    }

    @Test("Tab takes the grey word")
    func tabAccepts() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("l", into: &subject, sequence: &sequence)
        #expect(tab(into: &subject, sequence: &sequence).action == .editing)
        // `let` brings the space that follows it.
        #expect(line(&subject) == "let ")
    }

    @Test("With nothing grey to take, Tab opens the box instead")
    func tabFallsBackToThePanel() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSystem.", into: &subject, sequence: &sequence)
        #expect(ghost(&subject).text.isEmpty)

        _ = tab(into: &subject, sequence: &sequence)
        let opened = subject.isPanelOpen
        #expect(opened)
    }

    @Test("A receiver's dot comes with it")
    func ghostCarriesItsSuffix() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSy", into: &subject, sequence: &sequence)
        #expect(ghost(&subject).text == "stem")

        _ = tab(into: &subject, sequence: &sequence)
        #expect(line(&subject) == "fileSystem.")
    }

    @Test("A receiver a module adds later is ghosted like any other")
    func ghostsWhatArrivesLater() {
        var sequence: UInt32 = 1
        var before = editor()
        type("pi", into: &before, sequence: &sequence)
        #expect(ghost(&before).text.isEmpty, "nothing answers to pi yet")

        sequence = 1
        var after = editor(withLatecomer: true)
        type("pi", into: &after, sequence: &sequence)
        #expect(ghost(&after).text == "ppo")

        _ = tab(into: &after, sequence: &sequence)
        #expect(line(&after) == "pippo")
    }

    @Test("Nothing typed, nothing suggested")
    func silenceOnAnEmptyLine() {
        var sequence: UInt32 = 1
        var subject = editor()
        #expect(ghost(&subject).text.isEmpty)

        type("fileSystem.list ", into: &subject, sequence: &sequence)
        #expect(ghost(&subject).text.isEmpty, "a value is not guessed at")
    }

    @Test("The grey word follows what the verbs of a receiver are")
    func ghostsAVerb() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSystem.cha", into: &subject, sequence: &sequence)
        #expect(ghost(&subject).text == "ngeDir")

        _ = tab(into: &subject, sequence: &sequence)
        #expect(line(&subject) == "fileSystem.changeDir")
    }
}
