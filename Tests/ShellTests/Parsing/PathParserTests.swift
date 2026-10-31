//
//  PathParserTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
@testable import ShellLanguage

/// Taking a path apart.
///
/// Nothing here touches a disk: what is being tested is that the two separators
/// keep meaning two different things, and that a path which says something
/// impossible is refused before anything is opened on the strength of it.
@Suite("Path syntax")
struct PathParserTests {

    private func parts(_ text: String) -> PathParts? {
        text.withCString { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: text.count) { bytes in
                guard case .success(let parts) = PathParser.parse(
                    bytes,
                    count: text.count,
                    span : Span(start: 0, count: text.count)
                ) else { return nil }

                return parts
            }
        }
    }

    private func failure(_ text: String) -> PathFailure? {
        text.withCString { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: text.count) { bytes in
                guard case .failure(let why) = PathParser.parse(
                    bytes,
                    count: text.count,
                    span : Span(start: 0, count: text.count)
                ) else { return nil }

                return why
            }
        }
    }

    private func word(
        _ span   : Span,
          of text: String
    ) -> String {
        String(text.dropFirst(span.start).prefix(span.count))
    }


    @Test("the example from the design, taken apart")
    func theWholeThing() {
        let text = "reix::app::childPalle/miao/file.txt"

        guard let parts = parts(text) else {
            Issue.record("the path was refused")
            return
        }

        #expect(parts.isRooted)
        #expect(word(parts.root, of: text) == "reix")

        #expect(parts.containerCount == 2)
        #expect(word(parts.containers[0], of: text) == "app")
        #expect(word(parts.containers[1], of: text) == "childPalle")

        #expect(parts.folderCount == 2)
        #expect(word(parts.folders[0], of: text) == "miao")
        #expect(word(parts.folders[1], of: text) == "file.txt")

        #expect(word(parts.leaf, of: text) == "file.txt")
    }


    @Test("a path with no crossing is relative and names only folders")
    func relative() {
        let text = "miao/file.txt"

        guard let parts = parts(text) else {
            Issue.record("the path was refused")
            return
        }

        #expect(!parts.isRooted)
        #expect(parts.containerCount == 0)
        #expect(parts.folderCount == 2)
        #expect(word(parts.folders[0], of: text) == "miao")
        #expect(word(parts.leaf, of: text) == "file.txt")
    }


    @Test("one name is one name, crossed into or not")
    func single() {
        guard let bare = parts("file.txt"), let crossed = parts("reix::app") else {
            Issue.record("a one-name path was refused")
            return
        }

        #expect(!bare.isRooted)
        #expect(bare.folderCount == 1)
        #expect(bare.containerCount == 0)

        #expect(crossed.isRooted)
        #expect(crossed.containerCount == 1)
        #expect(crossed.folderCount == 0)
        #expect(word(crossed.containers[0], of: "reix::app") == "app")
        #expect(word(crossed.root, of: "reix::app") == "reix")
    }


    @Test("naming only a root names a place and nothing in it")
    func rootAlone() {
        let text = "reix::app"

        guard let parts = parts(text) else {
            Issue.record("the path was refused")
            return
        }

        #expect(parts.leaf.count == 0)
    }


    @Test("a lone colon is not a separator")
    func loneColon() {
        #expect(failure("reix:app") == .loneColon)
        #expect(failure("a/b:c") == .loneColon)
    }


    @Test("nothing between two separators is nothing, and is refused")
    func emptySegments() {
        #expect(failure("") == .emptySegment)
        #expect(failure("reix::app/") == .emptySegment)
        #expect(failure("a//b") == .emptySegment)
        #expect(failure("reix::::app") == .emptySegment)
    }


    @Test("a crossing with nothing after it names the place crossed into")
    func trailingCrossing() {
        guard let machine = parts("reix::"), let inside = parts("reix::app::") else {
            Issue.record("a trailing crossing was refused")
            return
        }

        #expect(machine.isRooted)
        #expect(word(machine.root, of: "reix::") == "reix")
        #expect(machine.containerCount == 0)
        #expect(machine.folderCount == 0)
        #expect(machine.leaf.count == 0)

        #expect(inside.containerCount == 1)
        #expect(word(inside.containers[0], of: "reix::app::") == "app")
        #expect(inside.folderCount == 0)
    }


    @Test("a path deeper than there is room for is refused, not truncated")
    func tooDeep() {
        #expect(failure("r::a::b::c::d::e::f") == .tooDeep)
        #expect(failure("a/b/c/d/e/f/g/h/i/j") == .tooDeep)
    }


    @Test("a crossing after folders keeps the folders where they were written")
    func crossingBindsTighter() {
        // `child` is the first name after the last crossing, so it is the
        // container, and everything after the slashes is inside it.
        let text = "reix::app::child/one/two"

        guard let parts = parts(text) else {
            Issue.record("the path was refused")
            return
        }

        #expect(parts.containerCount == 2)
        #expect(word(parts.containers[1], of: text) == "child")
        #expect(parts.folderCount == 2)
        #expect(word(parts.folders[0], of: text) == "one")
    }
}
