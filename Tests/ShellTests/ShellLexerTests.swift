//
//  ShellLexerTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

private func scan(_ source: String) -> ShellTokenStream {
    let bytes = Array(source.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return ShellTokenStream() }
        return ShellLexer.scan(base, count: buffer.count)
    }
}

private func kinds(_ stream: ShellTokenStream) -> [ShellTokenKind] {
    (0..<stream.count).compactMap { stream.token(at: $0)?.kind }
}

private func text(
    _ stream: ShellTokenStream,
    _ index : Int,
    of      : String
) -> String {
    guard let token = stream.token(at: index) else { return "" }
    let bytes = Array(of.utf8)
    return String(decoding: bytes[Int(token.start)..<token.end], as: UTF8.self)
}

/// The reading `TypedShellParser.completeness` did before the lexer took the
/// job over, kept here as the thing the new one has to agree with.
private func referenceCompleteness(_ source: String) -> ShellCompleteness {
    var parentheses = 0
    var braces      = 0
    var quoted      = false
    for (index, byte) in Array(source.utf8).enumerated() {
        if byte == 0x22 { quoted.toggle() }
        if !quoted {
            if byte == 0x28 { parentheses += 1 }
            if byte == 0x29 {
                guard parentheses > 0 else { return .invalid(column: index) }
                parentheses -= 1
            }
            if byte == 0x7B { braces += 1 }
            if byte == 0x7D {
                guard braces > 0 else { return .invalid(column: index) }
                braces -= 1
            }
        }
    }
    if quoted || parentheses > 0 || braces > 0 {
        return .incomplete(indent: parentheses + braces)
    }
    return .complete
}

@Suite("Shell lexer")
struct ShellLexerTests {

    @Test("A written call reads as the pieces it is made of")
    func writtenCall() {
        let source = "fileSystem.changeDir(at: \"vault\")"
        let stream = scan(source)
        #expect(kinds(stream) == [
            .name, .dot, .name, .openParenthesis, .name, .colon, .text, .closeParenthesis,
        ])
        #expect(text(stream, 0, of: source) == "fileSystem")
        #expect(text(stream, 6, of: source) == "\"vault\"")
        #expect(stream.completeness == .complete)
    }

    @Test("A path is one token, and a dotted name is not")
    func pathsAndDottedNames() {
        let path = scan("changeDir reix::app/doc")
        #expect(kinds(path) == [.name, .path])
        #expect(text(path, 1, of: "changeDir reix::app/doc") == "reix::app/doc")

        // `a.txt` may be a word or a member of `a`. Which one is a question
        // about the call it sits in, and this reads bytes.
        #expect(kinds(scan("read a.txt")) == [.name, .name, .dot, .name])
    }

    @Test("A quote nobody closed keeps the line before it")
    func unterminatedText() {
        let source = "fileSystem.write(at: memo.txt, text: \"still typing"
        let stream = scan(source)
        #expect(stream.count > 8)
        let last = stream.token(at: stream.count - 1)
        #expect(last?.kind == .text)
        #expect(last?.state == .unterminated)

        // Everything before the quote is read exactly as it would have been.
        #expect(stream.token(at: 0)?.kind == .name)
        #expect(stream.token(at: 0)?.state == .valid)
        #expect(text(stream, 0, of: source) == "fileSystem")
        #expect(stream.completeness == .incomplete(indent: 1))
    }

    @Test("A closure still open is tokens, not a refusal")
    func openClosure() {
        let stream = scan("list.filter { $0.isFolder")
        #expect(kinds(stream) == [
            .name, .dot, .name, .openBrace, .placeholder, .dot, .name,
        ])
        #expect(stream.completeness == .incomplete(indent: 1))
    }

    @Test("What ends where the input ends can still grow")
    func growingTokens() {
        let stream = scan("fileSystem.chang")
        #expect(stream.token(at: 2)?.kind == .name)
        #expect(stream.token(at: 2)?.state == .growing)
        // The same name with anything after it is finished.
        #expect(scan("fileSystem.chang ").token(at: 2)?.state == .valid)
    }

    @Test("A byte that starts nothing is one invalid token, not the end of the reading")
    func invalidBytes() {
        let source = "list ??? free"
        let stream = scan(source)
        #expect(kinds(stream) == [.name, .unknown, .unknown, .unknown, .name])
        #expect(stream.token(at: 1)?.state == .invalid)
        #expect(stream.token(at: 4)?.state == .growing)
        #expect(stream.completeness == .complete)
    }

    @Test("A closer with no opener is invalid where it stands")
    func unbalancedClosers() {
        let stream = scan("shell.help())")
        #expect(stream.completeness == .invalid(column: 12))
        #expect(stream.token(at: stream.count - 1)?.state == .invalid)
    }

    @Test("The cursor finds the token it is touching, or the one before it")
    func cursorContext() {
        let source = "fileSystem.changeDir vault"
        let stream = scan(source)
        #expect(stream.index(touching: 0) == 0)
        // Just past the last byte of `changeDir` is somebody typing it.
        #expect(stream.index(touching: 20) == 2)
        #expect(stream.token(at: stream.index(before: 21)!)?.kind == .name)
    }

    @Test("Completeness agrees with the reading it replaced")
    func completenessIsUnchanged() {
        for source in [
            "shell.help()",
            "fileSystem.write(at: a, text: \"hi\")",
            "list.filter { $0.isFolder }",
            "list.filter { $0.isFolder",
            "shell.help(",
            "shell.help())",
            "\"unclosed",
            "a \"quoted ) inside\" b",
            "{ { } ",
            "}",
            "",
            "   ",
            "let x = list, x.count",
        ] {
            let bytes = Array(source.utf8)
            let mine  = bytes.withUnsafeBufferPointer { buffer -> ShellCompleteness in
                guard let base = buffer.baseAddress else { return .complete }
                return TypedShellParser.completeness(base, count: buffer.count)
            }
            #expect(mine == referenceCompleteness(source), "completeness of \(source)")
        }
    }

    @Test("More tokens than there is room for are marked, not dropped silently")
    func truncation() {
        var source = ""
        for _ in 0..<(ShellTokenStream.capacity + 20) { source += "a " }
        let stream = scan(source)
        #expect(stream.count == ShellTokenStream.capacity)
        #expect(stream.truncated)
        #expect(stream.token(at: 0)?.kind == .name)
    }
}
