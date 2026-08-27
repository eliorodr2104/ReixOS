//
//  SharingTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// Handing a piece of one container to somebody else.
///
/// What makes this different from the tests above is the shape of the root: a
/// folder, or even a single file, standing in for a container. Containment has
/// to keep meaning the same thing when the boundary is not a container at all,
/// because that is the whole mechanism by which a share is narrow.
@Suite("Sharing")
struct SharingTests {

    private static let sectors: UInt64 = 32768

    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>) -> Void) {
        let disk = MemoryDisk(sectors: Self.sectors)

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
    ) -> UInt32? {
        let n = name(text)
        let made = fs.create(n.0, length: n.1, kind: kind, in: folder)
        return made.status == .ok ? made.object : nil
    }

    private func inside(
        _ fs: inout FileSystem<MemoryDisk>,
        _ object: UInt32,
        _ root: UInt32
    ) -> Bool {
        fs.contains(object, within: root)
    }

    private func called(
        _ fs: inout FileSystem<MemoryDisk>,
        _ object: UInt32
    ) -> String {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }

        let length = fs.name(of: object, into: buffer)
        let bytes  = buffer.assumingMemoryBound(to: UInt8.self)

        var text = ""
        for index in 0..<length { text.append(Character(UnicodeScalar(bytes[index]))) }

        return text
    }


    @Test("a folder is a boundary as good as a container")
    func aFolderIsARoot() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            guard let shared  = make(&fs, "shared", .folder, in: root),
                  let inner   = make(&fs, "inner",  .folder, in: shared),
                  let gift    = make(&fs, "gift.txt", .file, in: shared),
                  let deep    = make(&fs, "deep.txt", .file, in: inner),
                  let private_ = make(&fs, "private.txt", .file, in: root)
            else {
                Issue.record("the tree was not built")
                return
            }

            // Everything under the shared folder is inside it, at any depth.
            #expect(inside(&fs, gift, shared))
            #expect(inside(&fs, inner, shared))
            #expect(inside(&fs, deep, shared))
            #expect(inside(&fs, shared, shared))

            // And nothing beside it is.
            #expect(!inside(&fs, private_, shared))
            #expect(!inside(&fs, root, shared))
        }
    }


    @Test("a single file is a boundary containing only itself")
    func aFileIsARoot() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            guard let gift    = make(&fs, "gift.txt", .file, in: root),
                  let sibling = make(&fs, "other.txt", .file, in: root)
            else {
                Issue.record("the files were not created")
                return
            }

            #expect(inside(&fs, gift, gift))
            #expect(!inside(&fs, sibling, gift))
            #expect(!inside(&fs, root, gift))
        }
    }


    @Test("a share crossing containers is still bounded by what was shared")
    func acrossContainers() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            let alpha = fs.createContainer(
                name("alpha").0, length: 5, quota: 32, in: root
            ).object
            let beta = fs.createContainer(
                name("beta").0, length: 4, quota: 32, in: root
            ).object

            guard let gift   = make(&fs, "gift.txt", .file, in: alpha),
                  let secret = make(&fs, "secret.txt", .file, in: alpha),
                  let mine   = make(&fs, "mine.txt", .file, in: beta)
            else {
                Issue.record("the files were not created")
                return
            }

            // Holding the gift is holding the gift, and not alpha.
            #expect(inside(&fs, gift, gift))
            #expect(!inside(&fs, secret, gift))
            #expect(!inside(&fs, alpha, gift))

            // And beta still cannot see into alpha by any other route.
            #expect(!inside(&fs, gift, beta))
            #expect(inside(&fs, mine, beta))
        }
    }


    @Test("everything on the disk knows what it is called")
    func namesComeFromTheParent() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            let alpha = fs.createContainer(
                name("alpha").0, length: 5, quota: 32, in: root
            ).object

            guard let folder = make(&fs, "docs", .folder, in: alpha),
                  let file   = make(&fs, "gift.txt", .file, in: folder)
            else {
                Issue.record("the tree was not built")
                return
            }

            #expect(called(&fs, root) == "reix")
            #expect(called(&fs, alpha) == "alpha")
            #expect(called(&fs, folder) == "docs")
            #expect(called(&fs, file) == "gift.txt")
        }
    }


    @Test("a badge carries an object, an incarnation of it, and what may be done to it")
    func badgesRoundTrip() {
        let layout = FSBadge(objectCount: 512)

        let held: [FSRights] = [
            [], .reader, .occupant, .everything, [.unmount], [.lookup, .delegate]
        ]

        for object in [UInt32(0), 1, 7, 511] {
            for generation in [UInt32(0), 1, 4095] {
                for rights in held {
                    let badge = layout.encode(
                        object: object, generation: generation, rights: rights
                    )

                    #expect(layout.object(of: badge) == object)
                    #expect(layout.generation(of: badge) == generation)
                    #expect(FileOperation.rights(badge: badge) == rights)
                    #expect(layout.names(generation: generation, badge: badge))

                    // Never zero, because zero is what the kernel calls no badge
                    // at all, and object zero is the machine itself.
                    #expect(badge != 0)
                }
            }
        }

        #expect(layout.object(of: 0) == nil)
    }


    /// The three fields do not bleed into each other. Rights at the top, the
    /// object at the bottom, the generation in between: a badge holding every
    /// right must still name the object it was made for, and one holding none
    /// must not read as holding some.
    @Test("the three parts of a badge stay out of each other's way")
    func badgeFieldsAreDisjoint() {
        let layout = FSBadge(objectCount: 512)

        let full = layout.encode(object: 511, generation: 4095, rights: .everything)
        #expect(layout.object(of: full) == 511)
        #expect(layout.generation(of: full) == 4095)
        #expect(FileOperation.rights(badge: full) == .everything)

        let bare = layout.encode(object: 511, generation: 4095, rights: [])
        #expect(layout.object(of: bare) == 511)
        #expect(layout.generation(of: bare) == 4095)
        #expect(FileOperation.rights(badge: bare).isEmpty)

        // A handle is its own encoding now, and carries no rights at all: it has
        // no room made for them, which is what the generation gained.
        let handle = layout.handles.encode(object: 7, generation: 3)
        #expect(layout.handles.object(of: handle) == 7)
        #expect(layout.handles.generation(of: handle) == 3)
    }


    /// What the rights cost, now that the word is sixty-four bits.
    ///
    /// Nothing. The rights sit in the top eight of a sixty-four bit session and
    /// the object number in the bottom ten, so the generation gets the full
    /// thirty-two a record's counter has - on this disk and on any disk. It used
    /// to get whatever was left of a thirty-two bit word after both, which was
    /// fourteen bits on a sixteen megabyte disk: sixteen thousand removals of one
    /// slot before an old capability matched a new object.
    @Test("the generation spans every reuse a record can count")
    func generationSpanIsKnown() {
        // Thirty-two bits, because that is what `FSObject.generation` is and the
        // handle is a thirty-two bit word too. Wider here would be a span one of
        // the two comparisons could not make.
        #expect(FSBadge(objectCount: 512).generationSpan  == 1 << 32)
        #expect(FSBadge(objectCount: 4096).generationSpan == 1 << 32)

        // Enough object bits to name every slot, and one more because the
        // object travels stored plus one.
        #expect(FSBadge(objectCount: 512).objectBits == 10)

        // And the handle, which is where the width still costs something: a
        // thirty-two bit word with ten bits of object leaves twenty-two of
        // generation, so *that* is the number a slot may be reused.
        #expect(FSBadge(objectCount: 512).handles.generationSpan == 1 << 22)

        // Where the shape breaks down is now a disk with a slot for every
        // fifty-six bit object number, which is not a disk. The old cliff was at
        // sixteen million slots.
        let saturated = FSBadge(objectCount: 1 << 24)
        #expect(saturated.objectBits == 25)
        #expect(saturated.generationSpan == 1 << 31)
    }
}
