//
//  TypedShellRuntimeTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import Testing
import Foundation
import ReixABI
import ShellLanguage

private final class TypedExecutionProbe: @unchecked Sendable {
    var passed = false
}

@Suite("Typed shell runtime")
struct TypedShellRuntimeTests {
    @Test("fileSystem canonical and compact forms execute through one signature")
    func fileSystemExecution() {
        // Swift Testing workers use a deliberately small stack. The bounded
        // freestanding evaluator keeps its arenas inline, so exercise it on a
        // normal application-sized stack just as ShellBench and the shell do.
        let probe  = TypedExecutionProbe()
        let worker = Thread {
            var changeParameters = InlineArray<4, TypedShellParameter?>(repeating: nil)
            changeParameters[0] = TypedShellParameter("at")
            var signatures = InlineArray<1, TypedShellSignature?>(repeating: nil)
            signatures[0] = TypedShellSignature(
                namespace     : "fileSystem",
                name          : "changeDir",
                parameters    : changeParameters,
                parameterCount: 1,
                effect        : .session
            )

            let source = Array("fileSystem.changeDir(at: \"archive\")".utf8)
            source.withUnsafeBufferPointer { bytes in
                guard case .success(let program) = TypedShellParser.parse(bytes.baseAddress!, count: bytes.count) else { return }
                var runtime = TypedShellRuntime()
                var arena   = TypedShellSequenceArena()
                let result  = signatures.span.withUnsafeBufferPointer { table in
                    runtime.execute(
                        program,
                        source: bytes.baseAddress!,
                        count: bytes.count,
                        signatures: table,
                        arena: &arena
                    ) { invocation in
                        guard invocation.signatureIndex == 0,
                              invocation.argumentCount == 1,
                              invocation.arguments[0]?.value == .text(ShellText("archive")!)
                        else { return .failure(1) }
                        return .success(.number(7))
                    }
                }
                probe.passed = result == .success(.number(7))
            }
        }
        worker.stackSize = 8 * 1024 * 1024
        worker.start()
        while !worker.isFinished { Thread.sleep(forTimeInterval: 0.001) }
        #expect(probe.passed)
    }

    @Test("typed parser accepts the complete language examples")
    func parserExamples() {
        let examples = [
            "move from draft to archive",
            "move draft archive",
            "fileSystem.move(from: source, to: destination)",
            "fileSystem.changeDir(at: destination)",
            "changeDir destination",
            "fileSystem.createDirectory(at: docs)",
            "fileSystem.createFile(at: draft)",
            "fileSystem.write(at: draft, text: \"hello\")",
            "let folders = list.filter { $0.isFolder }, folders.filter { !$0.name.contains(\"1\") }.sorted { $0.name < $1.name }",
            "list.map { $0.name }.compactMap { $0 }.flatMap { list }",
        ]
        for source in examples {
            source.utf8.withContiguousStorageIfAvailable { bytes in
                guard case .success(let program) = TypedShellParser.parse(bytes.baseAddress!, count: bytes.count) else {
                    Issue.record("typed parser refused: \(source)")
                    return
                }
                #expect(program.count > 0)
            }
        }
    }

    @Test("editor uses semantic keys, multiline completeness and UTF-8 boundaries")
    func editor() {
        var editor   = ShellLineEditor()
        var sequence : UInt32 = 1
        func insertion(_ text: [UInt8]) -> TerminalInputEvent {
            defer { sequence += 1 }
            return text.withUnsafeBufferPointer { TerminalInputEvent(sequence: sequence, bytes: $0.baseAddress!, count: $0.count) }
        }
        for byte in Array("list.filter {".utf8) { _ = editor.apply(insertion([byte])) }
        let newline = editor.apply(TerminalInputEvent(kind: .enter, sequence: sequence))
        #expect(newline.action == .editing)
        #expect(editor.count > "list.filter {".utf8.count)
        for byte in Array("$0.isFolder }".utf8) { _ = editor.apply(insertion([byte])) }
        let submitted = editor.apply(TerminalInputEvent(kind: .enter, sequence: sequence + 1))
        guard case .submitted(let count) = submitted.action else { Issue.record("complete multiline input did not submit"); return }
        #expect(count == editor.count)
        editor.reset()

        _ = editor.apply(insertion([0xC3, 0xA8]))
        #expect(editor.cursor == 2)
        _ = editor.apply(TerminalInputEvent(kind: .left, sequence: sequence + 2))
        #expect(editor.cursor == 0)
        _ = editor.apply(TerminalInputEvent(kind: .right, sequence: sequence + 3))
        #expect(editor.cursor == 2)

        let middle = editor.apply(TerminalInputEvent(kind: .left, sequence: sequence + 4))
        guard let patch = middle.patch else { Issue.record("cursor update did not produce a patch"); return }
        #expect(patch.kind == .replaceBuffer)
        let replacement = editor.apply(insertion([UInt8(ascii: "x")]))
        guard let row = replacement.patch else { Issue.record("middle insertion did not redraw"); return }
        #expect(row.kind == .replaceBuffer)
        #expect(row.cursorColumn == 7)
        #expect(row.count == 9)
    }

    @Test("multiline movement follows logical rows and history only at boundaries")
    func multilineMovement() {
        var editor = ShellLineEditor()
        let source = Array("ab\n12345\nèx".utf8)
        _ = source.withUnsafeBufferPointer {
            editor.apply(TerminalInputEvent(sequence: 1, bytes: $0.baseAddress!, count: $0.count))
        }
        #expect(editor.cursor == source.count)
        _ = editor.apply(TerminalInputEvent(kind: .up, sequence: 2))
        #expect(editor.cursor == 5)
        _ = editor.apply(TerminalInputEvent(kind: .up, sequence: 3))
        #expect(editor.cursor == 2)
        _ = editor.apply(TerminalInputEvent(kind: .down, sequence: 4))
        #expect(editor.cursor == 5)
        _ = editor.apply(TerminalInputEvent(kind: .home, sequence: 5))
        #expect(editor.cursor == 3)
        _ = editor.apply(TerminalInputEvent(kind: .end, sequence: 6))
        #expect(editor.cursor == 8)
        let replacement = editor.apply(TerminalInputEvent(kind: .delete, sequence: 7))
        #expect(replacement.patch?.kind == .replaceBuffer)
        #expect(replacement.patch?.previousRows == 3)

        editor.reset()
        let help = Array("help".utf8)
        _ = help.withUnsafeBufferPointer {
            editor.apply(TerminalInputEvent(sequence: 8, bytes: $0.baseAddress!, count: $0.count))
        }
        _ = editor.apply(TerminalInputEvent(kind: .enter, sequence: 9))
        editor.reset()
        _ = editor.apply(TerminalInputEvent(kind: .up, sequence: 10))
        #expect(editor.count == 4)
        _ = editor.apply(TerminalInputEvent(kind: .down, sequence: 11))
        #expect(editor.count == 0)
    }
}
