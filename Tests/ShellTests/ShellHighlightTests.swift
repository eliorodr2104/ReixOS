//
//  ShellHighlightTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

private enum HighlightFiles: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("fileSystem", summary: "a container")
    }
    static var commandCount: Int { 2 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        switch index {
            case 0:
                return ShellCommandDescriptor(
                    code     : 0,
                    verb     : "move",
                    signature: TypedShellSignature(namespace: "fileSystem", name: "changeDir", TypedShellParameter("at")),
                    summary  : "change this session's directory"
                )
            default:
                return ShellCommandDescriptor(
                    code     : 1,
                    verb     : "write",
                    signature: TypedShellSignature(
                        namespace: "fileSystem",
                        name     : "write",
                        TypedShellParameter("at"),
                        TypedShellParameter("text")
                    ),
                    summary  : "replace what a file says"
                )
        }
    }
}

private func highlighted(_ text: String) -> [(role: ReixTextSurfaceStyleRole, offset: Int, length: Int)] {
    var catalog = ShellCatalog()
    _ = catalog.merge(HighlightFiles.self)
    var editor   = ShellLineEditor(catalog: catalog)
    var sequence : UInt32 = 1
    for byte in Array(text.utf8) {
        var payload = byte
        let record  = withUnsafePointer(to: &payload) {
            ReixInputRecord(kind: .insert, sequence: sequence, bytes: $0, count: 1)!
        }
        _ = editor.apply(record)
        sequence += 1
    }
    var spans: [(ReixTextSurfaceStyleRole, Int, Int)] = []
    _ = editor.withFrame { source in
        for index in 0..<source.styleCount {
            let span = source.styles![index]
            spans.append((span.role, Int(span.offset), Int(span.length)))
        }
        return true
    }
    return spans.map { (role: $0.0, offset: $0.1, length: $0.2) }
}

@Suite("Shell highlighting")
struct ShellHighlightTests {

    @Test("The prompt, the receiver and its verb each get their own span")
    func writtenCall() {
        let spans = highlighted("fileSystem.changeDir vault")
        #expect(spans.count >= 3)
        #expect(spans[0].role == .prompt)
        #expect(spans[0].offset == 0)

        // Offsets are in the frame, which begins with the prompt.
        let prompt = ShellLineEditor.promptBytes
        #expect(spans[1].role == .namespace)
        #expect(spans[1].offset == prompt)
        #expect(spans[1].length == 10)
        #expect(spans[2].role == .command)
        #expect(spans[2].offset == prompt + 11)
        #expect(spans[2].length == 9)

        // A word is a value and carries no colour of its own.
        #expect(!spans.contains { $0.offset == prompt + 21 })
    }

    @Test("A string, a label and a number are told apart")
    func argumentRoles() {
        let spans = highlighted("fileSystem.write(at: memo.txt, text: \"hi\")")
        #expect(spans.contains { $0.role == .label })
        #expect(spans.contains { $0.role == .text })
        #expect(spans.contains { $0.role == .namespace })
        #expect(spans.contains { $0.role == .command })
    }

    @Test("What is still being typed is not painted as an error")
    func growingName() {
        let typing = highlighted("fileSystem.chan")
        #expect(typing.contains { $0.role == .incomplete })
        #expect(!typing.contains { $0.role == .error })

        // The same name, finished and followed by something, is wrong.
        let finished = highlighted("fileSystem.chan vault")
        #expect(finished.contains { $0.role == .error })
    }

    @Test("Spans arrive sorted and apart, which is what the frame requires")
    func spansAreOrdered() {
        let spans       = highlighted("fileSystem.write(at: memo.txt, text: \"hi\")")
        var previousEnd = 0
        for span in spans {
            #expect(span.offset >= previousEnd)
            #expect(span.length > 0)
            previousEnd = span.offset + span.length
        }
    }
}
