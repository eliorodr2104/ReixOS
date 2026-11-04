//
//  ContainerTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// Containers: a boundary on one disk, and a room that was given rather than
/// found.
///
/// The two claims worth testing are opposite in shape. Containment is about
/// what a walk up the tree says, and it has to hold for numbers a caller
/// *guessed* rather than numbers it was given. Room is about arithmetic that
/// must balance: what is given comes out of somewhere, and what is released
/// goes back to the same place.
@Suite("Containers")
struct ContainerTests {

    private static let sectors: UInt64 = 32768


    private func withFileSystem(
        _ body: (inout FileSystem<MemoryDisk>) -> Void
    ) {
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

    @discardableResult
    private func makeFile(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        in folder: UInt32
    ) -> UInt32? {
        let n = name(text)
        let made = fs.create(n.0, length: n.1, kind: .file, in: folder)
        return made.status == .ok ? made.object : nil
    }

    private func makeContainer(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        quota: UInt32,
        in folder: UInt32
    ) -> (status: FSStatus, object: UInt32) {
        let n = name(text)
        return fs.createContainer(n.0, length: n.1, quota: quota, in: folder)
    }

    private func fill(
        _ fs: inout FileSystem<MemoryDisk>,
        _ file: UInt32,
        bytes: Int
    ) -> FSStatus {
        let out = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { out.deallocate() }
        out.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

        return fs.write(file, at: 0, from: UnsafeRawPointer(out), count: UInt64(bytes)).status
    }


    /// `#expect` cannot call a mutating method on the value it is given, and
    /// every question this file asks the file system is mutating: it reads
    /// blocks through a scratch buffer. Hence the wrappers.
    private func inside(
        _ fs: inout FileSystem<MemoryDisk>,
        _ object: UInt32,
        _ root: UInt32
    ) -> Bool {
        fs.contains(object, within: root)
    }

    private func free(_ fs: inout FileSystem<MemoryDisk>) -> UInt32 {
        fs.freeBlocks()
    }

    private func quota(_ fs: inout FileSystem<MemoryDisk>, _ container: UInt32) -> UInt32 {
        fs.room(of: container)?.quota ?? UInt32.max
    }

    private func used(_ fs: inout FileSystem<MemoryDisk>, _ container: UInt32) -> UInt32 {
        fs.room(of: container)?.used ?? UInt32.max
    }

    private func grant(
        _ fs: inout FileSystem<MemoryDisk>,
        _ blocks: UInt32,
        _ parent: UInt32,
        _ child: UInt32
    ) -> FSStatus {
        fs.grantQuota(blocks, from: parent, to: child)
    }

    private func drop(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        _ folder: UInt32
    ) -> FSStatus {
        let n = name(text)
        return fs.remove(n.0, length: n.1, from: folder)
    }


    // MARK: - The boundary

    @Test("the machine's root contains everything, including itself")
    func rootContainsAll() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            guard let file = makeFile(&fs, "a.txt", in: root) else {
                Issue.record("the file was not created")
                return
            }

            #expect(inside(&fs, root, root))
            #expect(inside(&fs, file, root))
        }
    }


    @Test("a container does not contain what is outside it, however it is named")
    func aContainerIsAWall() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            let made = makeContainer(&fs, "app", quota: 64, in: root)
            #expect(made.status == .ok)
            let app = made.object

            guard let mine   = makeFile(&fs, "mine.txt",  in: app),
                  let outside = makeFile(&fs, "other.txt", in: root)
            else {
                Issue.record("the files were not created")
                return
            }

            #expect(inside(&fs, mine, app))
            #expect(inside(&fs, app, app))

            // The whole point: a number belonging to somewhere else stays
            // somewhere else. Guessing it changes nothing.
            #expect(!inside(&fs, outside, app))
            #expect(!inside(&fs, root, app))

            // And the other way round, the root still sees both.
            #expect(inside(&fs, mine, root))
            #expect(inside(&fs, outside, root))
        }
    }


    @Test("two containers cannot see into each other")
    func siblingsAreBlind() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            let first  = makeContainer(&fs, "one", quota: 32, in: root).object
            let second = makeContainer(&fs, "two", quota: 32, in: root).object

            guard let mine = makeFile(&fs, "mine.txt", in: first),
                  let theirs = makeFile(&fs, "theirs.txt", in: second)
            else {
                Issue.record("the files were not created")
                return
            }

            #expect(!inside(&fs, theirs, first))
            #expect(!inside(&fs, mine, second))
            #expect(!inside(&fs, second, first))
        }
    }


    @Test("a container nested inside another is inside both")
    func nestingReachesUp() {
        withFileSystem { fs in
            let root  = FSLayout.rootObject
            let outer = makeContainer(&fs, "outer", quota: 64, in: root).object
            let inner = makeContainer(&fs, "inner", quota: 16, in: outer).object

            guard let deep = makeFile(&fs, "deep.txt", in: inner) else {
                Issue.record("the file was not created")
                return
            }

            #expect(inside(&fs, deep, inner))
            #expect(inside(&fs, deep, outer))
            #expect(inside(&fs, deep, root))
            #expect(!inside(&fs, outer, inner))
        }
    }


    @Test("a number that names nothing is inside nothing")
    func emptySlotsAreNotInside() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            #expect(!inside(&fs, 500, root))
            #expect(!inside(&fs, UInt32.max, root))
        }
    }


    // MARK: - The room

    @Test("a container is made out of its parent's room, not out of the disk")
    func roomComesFromTheParent() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            guard let before = fs.room(of: root) else {
                Issue.record("the root has no room")
                return
            }

            let made = makeContainer(&fs, "app", quota: 100, in: root)
            #expect(made.status == .ok)

            guard let after = fs.room(of: root),
                  let child = fs.room(of: made.object)
            else {
                Issue.record("the rooms cannot be read")
                return
            }

            #expect(child.quota == 100)
            #expect(after.quota == before.quota - 100)
        }
    }


    @Test("a container cannot give away room it has not got")
    func roomCannotBeInvented() {
        withFileSystem { fs in
            let root = FSLayout.rootObject
            let app  = makeContainer(&fs, "app", quota: 8, in: root).object

            // The child has eight blocks; a grandchild of sixteen is refused.
            let tooBig = makeContainer(&fs, "big", quota: 16, in: app)
            #expect(tooBig.status == .noSpace)

            // And the disk has far more than eight free, so this is the
            // container's limit talking and not the disk's.
            #expect(free(&fs) > 16)
        }
    }


    @Test("writing past a container's room is refused while the disk is empty")
    func theRoomIsTheLimit() {
        withFileSystem { fs in
            let root = FSLayout.rootObject
            let app  = makeContainer(&fs, "app", quota: 2, in: root).object

            guard let file = makeFile(&fs, "big.bin", in: app) else {
                Issue.record("the file was not created")
                return
            }

            // One block of the two went on the container's own directory, so
            // one block of payload fits and two do not.
            #expect(fill(&fs, file, bytes: 4096) == .ok)
            #expect(fill(&fs, file, bytes: 9000) == .noSpace)

            #expect(free(&fs) > 100)
        }
    }


    @Test("what a container uses is given back when its files are")
    func roomIsReturned() {
        withFileSystem { fs in
            let root = FSLayout.rootObject
            let app  = makeContainer(&fs, "app", quota: 32, in: root).object

            guard let file = makeFile(&fs, "big.bin", in: app) else { return }
            #expect(fill(&fs, file, bytes: 20000) == .ok)

            guard let full = fs.room(of: app) else { return }
            #expect(full.used > 4)

            #expect(drop(&fs, "big.bin", app) == .ok)

            guard let after = fs.room(of: app) else { return }
            #expect(after.used == full.used - 5)   // 20000 bytes is five blocks
            #expect(after.quota == 32)
        }
    }


    @Test("a container's room goes back to its parent when it is removed")
    func removalReturnsTheRoom() {
        withFileSystem { fs in
            let root = FSLayout.rootObject

            guard let before = fs.room(of: root) else { return }

            _ = makeContainer(&fs, "gone", quota: 50, in: root)
            #expect(drop(&fs, "gone", root) == .ok)

            guard let after = fs.room(of: root) else { return }

            // The room is back; the block the root's own folder grew by is not,
            // and is not meant to be.
            #expect(after.quota == before.quota)
        }
    }


    @Test("room may be handed down, and only down")
    func roomMovesDownward() {
        withFileSystem { fs in
            let root  = FSLayout.rootObject
            let outer = makeContainer(&fs, "outer", quota: 40, in: root).object
            let inner = makeContainer(&fs, "inner", quota: 4,  in: outer).object

            #expect(grant(&fs, 8, outer, inner) == .ok)
            #expect(quota(&fs, inner) == 12)

            // Not to something that is not directly inside it.
            let other = makeContainer(&fs, "other", quota: 4, in: root).object
            #expect(grant(&fs, 4, outer, other) == .notFound)

            // And not more than it has left.
            #expect(grant(&fs, 1000, outer, inner) == .noSpace)
        }
    }
}
