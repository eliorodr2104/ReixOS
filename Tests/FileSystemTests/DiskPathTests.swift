//
//  DiskPathTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// Writing a path back out.
///
/// The two separators have to come back the way they went in: `::` before a
/// container, `/` before anything else. A path that says otherwise is a path
/// that lies about where the boundaries are, which is the one thing the syntax
/// exists to show.
@Suite("Paths on the disk")
struct DiskPathTests {

    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>) -> Void) {
        let disk = MemoryDisk(sectors: 32768)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        body(&fs)
    }

    private func name(_ text: StaticString) -> (UnsafeRawPointer, Int) {
        (UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        _ kind: FSKind,
        in folder: UInt32
    ) -> UInt32 {
        let n = name(text)
        return fs.create(n.0, length: n.1, kind: kind, in: folder).object
    }

    private func container(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        _ room: UInt32,
        in folder: UInt32
    ) -> UInt32 {
        let n = name(text)
        return fs.createContainer(n.0, length: n.1, quota: room, in: folder).object
    }

    private func written(
        _ fs: inout FileSystem<MemoryDisk>,
        _ object: UInt32,
        from root: UInt32
    ) -> String {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 8)
        defer { buffer.deallocate() }

        let length = fs.path(of: object, within: root, into: buffer, capacity: 256)
        let bytes  = buffer.assumingMemoryBound(to: UInt8.self)

        var text = ""
        for index in 0..<length { text.append(Character(UnicodeScalar(bytes[index]))) }

        return text
    }


    @Test("the example from the design comes back out the way it went in")
    func theWholeThing() {
        withFileSystem { fs in
            let root  = FSLayout.rootObject
            let app   = container(&fs, "app", 128, in: root)
            let child = container(&fs, "childPalle", 64, in: app)
            let miao  = make(&fs, "miao", .folder, in: child)
            let file  = make(&fs, "file.txt", .file, in: miao)

            #expect(written(&fs, file, from: root) == "reix::app::childPalle/miao/file.txt")
            #expect(written(&fs, miao, from: root) == "reix::app::childPalle/miao")
            #expect(written(&fs, child, from: root) == "reix::app::childPalle")
            #expect(written(&fs, root, from: root) == "reix")
        }
    }


    @Test("a typed path never reports or leaves a partial answer")
    func typedPathRefusesShortWindows() {
        withFileSystem { fs in
            let root = FSLayout.rootObject
            let docs = make(&fs, "documents", .folder, in: root)
            let file = make(&fs, "note.txt", .file, in: docs)

            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0xEE, count: 8)

            let result = fs.pathResult(of: file, within: root, into: buffer, capacity: 8)

            #expect(result.status == .bufferTooSmall)
            #expect(result.length == 0)
            for index in 0..<8 {
                #expect(buffer.load(fromByteOffset: index, as: UInt8.self) == 0)
            }
        }
    }


    @Test("a path is written from the root the asker holds, not from the machine")
    func fromWhereYouStand() {
        withFileSystem { fs in
            let root = FSLayout.rootObject
            let app  = container(&fs, "app", 64, in: root)
            let docs = make(&fs, "docs", .folder, in: app)
            let file = make(&fs, "x.txt", .file, in: docs)

            // Somebody holding `app` sees their own world named first, and
            // nothing above it at all.
            #expect(written(&fs, file, from: app) == "app/docs/x.txt")
            #expect(written(&fs, app, from: app) == "app")
        }
    }


    @Test("there is no path to somewhere you cannot reach")
    func nothingOutside() {
        withFileSystem { fs in
            let root = FSLayout.rootObject
            let one  = container(&fs, "one", 32, in: root)
            let two  = container(&fs, "two", 32, in: root)
            let mine = make(&fs, "mine.txt", .file, in: two)

            #expect(written(&fs, mine, from: one) == "")
            #expect(written(&fs, root, from: one) == "")
            #expect(written(&fs, 900, from: root) == "")
        }
    }
}
