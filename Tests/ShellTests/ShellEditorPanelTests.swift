//
//  ShellEditorPanelTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

private enum PanelFiles: ShellCommandProvider {
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
            default:
                return ShellCommandDescriptor(
                    code     : 2,
                    verb     : "remove",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "remove", TypedShellParameter("at")),
                    sensitive: true,
                    summary  : "take it away"
                )
        }
    }
}

private func editor() -> ShellLineEditor {
    var catalog = ShellCatalog()
    _ = catalog.merge(PanelFiles.self)
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

private func press(
    _ key: ReixInputKey,
      into editor: inout ShellLineEditor,
      sequence: inout UInt32,
      modifiers: ReixInputModifiers = []
) -> ShellEditorUpdate {
    let record = ReixInputRecord(
        kind       : .key,
        modifiers  : modifiers,
        sequence   : sequence,
        logicalKey : key,
        physicalKey: 0x8000 | key.rawValue
    )!
    sequence += 1
    return editor.apply(record)
}

private func line(_ editor: inout ShellLineEditor) -> String {
    editor.withBytes { bytes, count in
        String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

private func overlay(_ editor: inout ShellLineEditor) -> String {
    var text = ""
    _ = editor.withFrame { source in
        guard let overlay = source.overlay, source.overlayLength > 0 else { return true }
        text = String(decoding: UnsafeBufferPointer(start: overlay, count: source.overlayLength), as: UTF8.self)
        return true
    }
    return text
}

@Suite("Shell editor panel")
struct ShellEditorPanelTests {

    @Test("Tab opens the box on what fits, and the line does not move")
    func tabOpens() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSystem.", into: &subject, sequence: &sequence)
        let before = line(&subject)

        #expect(press(.tab, into: &subject, sequence: &sequence).action == .editing)
        let opened = subject.isPanelOpen
        #expect(opened)
        #expect(line(&subject) == before)

        let drawn = overlay(&subject)
        #expect(drawn.contains("list"))
        #expect(drawn.contains("changeDir"))
    }

    @Test("Selecting is not accepting")
    func selectionDoesNotType() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSystem.", into: &subject, sequence: &sequence)
        _ = press(.tab, into: &subject, sequence: &sequence)
        let before = line(&subject)

        _ = press(.tab, into: &subject, sequence: &sequence)
        _ = press(.down, into: &subject, sequence: &sequence)
        _ = press(.up, into: &subject, sequence: &sequence)
        #expect(line(&subject) == before)
        let opened = subject.isPanelOpen
        #expect(opened)
    }

    @Test("Enter writes the selected candidate over what was typed of it")
    func acceptWrites() {
        var sequence: UInt32 = 1
        var subject = editor()
        // With nothing typed after the dot there is no grey word to take, so
        // Tab opens the box.
        type("fileSystem.", into: &subject, sequence: &sequence)
        _ = press(.tab, into: &subject, sequence: &sequence)
        let opened = subject.isPanelOpen
        #expect(opened)
        _ = press(.down, into: &subject, sequence: &sequence)

        #expect(press(.enter, into: &subject, sequence: &sequence).action == .editing)
        let closed = !subject.isPanelOpen
        #expect(closed)
        // list, remove, changeDir: shorter first, so one step down is remove.
        #expect(line(&subject) == "fileSystem.remove")
    }

    @Test("A receiver accepted brings its dot with it")
    func suffixFollows() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSy", into: &subject, sequence: &sequence)
        _ = press(.tab, into: &subject, sequence: &sequence)
        _ = press(.enter, into: &subject, sequence: &sequence)
        #expect(line(&subject) == "fileSystem.")
    }

    @Test("Esc closes the box and leaves the line alone")
    func cancelCloses() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSystem.", into: &subject, sequence: &sequence)
        _ = press(.tab, into: &subject, sequence: &sequence)
        let opened = subject.isPanelOpen
        #expect(opened)

        #expect(press(.cancel, into: &subject, sequence: &sequence).action == .editing)
        let closed = !subject.isPanelOpen
        #expect(closed)
        #expect(line(&subject) == "fileSystem.")
    }

    @Test("Typing closes it, because what it offered was about the line as it was")
    func typingCloses() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("fileSystem.", into: &subject, sequence: &sequence)
        _ = press(.tab, into: &subject, sequence: &sequence)
        type("l", into: &subject, sequence: &sequence)
        let closed = !subject.isPanelOpen
        #expect(closed)
        #expect(line(&subject) == "fileSystem.l")
    }

    @Test("A method arrives with its braces, and the cursor inside them")
    func closureTemplate() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("list.fil", into: &subject, sequence: &sequence)
        // `fil` has one answer, so Tab takes the grey word rather than opening
        // the box, and it still brings the braces.
        _ = press(.tab, into: &subject, sequence: &sequence)
        // Two spaces: one lands on each side of whatever is written between.
        #expect(line(&subject) == "list.filter {  }")

        // Typing now lands between the braces.
        type("$0.isFolder", into: &subject, sequence: &sequence)
        #expect(line(&subject) == "list.filter { $0.isFolder }")
    }

    @Test("The box scrolls to keep the selection in view")
    func panelScrolls() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("list.", into: &subject, sequence: &sequence)
        _ = press(.tab, into: &subject, sequence: &sequence)

        let first = overlay(&subject)
        #expect(first.contains("count"))

        // Ten steps down is past what the box shows at once.
        for _ in 0..<10 { _ = press(.down, into: &subject, sequence: &sequence) }
        let later = overlay(&subject)
        #expect(!later.contains("count"), "the window moved with the selection")
        #expect(later.contains("11 of 11") || later.contains("of 11"))
    }

    @Test("With nothing to offer, the box does not open")
    func nothingToOffer() {
        var sequence: UInt32 = 1
        var subject = editor()
        type("zzz", into: &subject, sequence: &sequence)
        #expect(press(.tab, into: &subject, sequence: &sequence).action == .refused)
        let closed = !subject.isPanelOpen
        #expect(closed)
    }
}
