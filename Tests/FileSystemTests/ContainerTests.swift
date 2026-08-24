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

        // A handle is a badge with no rights in it, and is never read for any.
        let handle = layout.handle(object: 7, generation: 3)
        #expect(FileOperation.rights(badge: handle).isEmpty)
        #expect(layout.object(of: handle) == 7)
    }


    /// What the rights cost. Eight bits of the word are no longer available to
    /// the generation, which is eight halvings of the ABA distance, and the
    /// number is here so it is a decision rather than a surprise.
    @Test("the generation still spans enough reuses of one slot")
    func generationSpanIsKnown() {
        #expect(FSBadge(objectCount: 512).generationSpan  == 1 << 14)
        #expect(FSBadge(objectCount: 4096).generationSpan == 1 << 11)

        // Enough object bits to name every slot, and one more because the
        // object travels stored plus one.
        #expect(FSBadge(objectCount: 512).objectBits == 10)

        // Where the shape breaks down: a disk with a slot for every object
        // number the word can hold leaves the generation nothing, and an old
        // badge for a reused slot matches again. Far from this machine's
        // five-hundred-odd slots, and worth having written down: the rights
        // moved that cliff from sixteen million slots down to sixteen million
        // divided by two hundred and fifty-six.
        let saturated = FSBadge(objectCount: 1 << 24)
        #expect(saturated.objectBits == 24)
        #expect(saturated.generationSpan == 1)
    }
}


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
