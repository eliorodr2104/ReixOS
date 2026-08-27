//
//  DecoderFailClosedTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What the decoder does with bytes that are not a record, and what a walk does
/// when it cannot finish.
///
/// Two clamps used to decide more than they were meant to. A record whose kind
/// byte is not a kind was clamped to `.free`, which is not a refusal but a
/// *semantic*: a free slot is one `create` hands out, so those blocks would be
/// given to a second owner while the map still called them used. An entry whose
/// length ran past the field was clamped to zero, which reads as an unused slot,
/// so `link` would lay a name over it. Both clamps are still there - the loops
/// need them - and neither decides anything any more: `standing` remembers what
/// was clamped and `fits` asks before it asks anything else.
///
/// The other half is the walking. `forEachEntry` returned nothing at all,
/// `lookup` returned `nil` and `isEmpty` returned `true`, so an unreadable
/// directory block was indistinguishable from an empty folder - and "the name is
/// not there" is exactly what authorises writing it.
@Suite("A decoder and a walk that fail closed")
struct DecoderFailClosedTests {

    private static let sectors: UInt64 = 4096      // 2 MiB
    private static let block = Int(FSLayout.blockSize)

    /// Where each field of a record sits, for a test that writes one by hand.
    private enum At {
        static let kind      = 0
        static let extents   = 1
        static let quota     = 32
        static let used      = 36
        static let container = 40
        static let parent    = 44
    }

    private func plan() -> FSLayout.Plan {
        FSLayout.Plan(sectorCount: Self.sectors, sectorSize: 512)!
    }

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
    }

    private func named(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    private func withDisk(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }

    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        kind: FSKind = .file,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        var made: UInt32? = nil

        named(name) { pointer, length in
            let result: (status: FSStatus, object: UInt32)
            if kind == .container {
                result = fs.createContainer(pointer, length: length, quota: 0, in: folder)
            } else {
                result = fs.create(pointer, length: length, kind: kind, in: folder)
            }
            if result.status == .ok { made = result.object }
        }

        if made == nil { Issue.record("the fixture object would not be made") }
        return made
    }

    /// Where object `index`'s record starts, in bytes into the disk.
    private func recordAt(_ fs: FileSystem<MemoryDisk>, _ index: UInt32) -> Int {
        Int(fs.plan.tableStart) * Self.block + Int(index) * Int(FSLayout.objectSize)
    }

    /// A folder's first directory block, in bytes into the disk.
    private func folderAt(
        _ fs: inout FileSystem<MemoryDisk>,
        _ index: UInt32
    ) -> Int? {
        guard let record = fs.object(index), record.extents > 0 else { return nil }
        return Int(record.runs[0].start) * Self.block
    }

    /// Whether the volume refuses to be written to.
    private func heldStill(
        _ fs: inout FileSystem<MemoryDisk>,
        _ disk: MemoryDisk
    ) -> Bool {
        let before = disk.writes

        var status = FSStatus.ok
        named("after.bin") { pointer, length in
            status = fs.create(
                pointer, length: length, kind: .file, in: FSLayout.rootObject
            ).status
        }

        return status != .ok && disk.writes == before
    }


    // MARK: - The record corpus

    @Test("the generic create door cannot bypass container admission")
    func genericCreateRefusesContainer() {
        withDisk { fs, disk in
            let before = disk.writes
            named("bypass") { pointer, length in
                #expect(fs.create(
                    pointer, length: length, kind: .container, in: FSLayout.rootObject
                ).status == .wrongKind)
            }
            #expect(disk.writes == before)
            #expect(!fs.inTransaction)
        }
    }

    @Test("a kind byte this format never writes is not a free slot")
    func unknownKindIsNotFree() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(FSLayout.objectSize), alignment: 8
        )
        defer { raw.deallocate() }

        var record = FSObject(kind: .file, created: 1)
        record.blocks = 0
        record.write(to: raw)

        #expect(FSObject(reading: raw).standing == .live)

        // Every byte that is not one of the four kinds, and there are two hundred
        // and fifty-two of them.
        for byte in 4...255 {
            raw.storeBytes(of: UInt8(byte), toByteOffset: At.kind, as: UInt8.self)

            let read = FSObject(reading: raw)

            // The clamp is still there, because every loop in this file system
            // asks the kind and a value outside the enum is not a value.
            #expect(read.kind == .free, "kind \(byte)")

            // And it decides nothing. This is the whole feature in three lines.
            #expect(!read.recordEncodingValid, "kind \(byte)")
            #expect(read.standing == .impossible, "kind \(byte)")
            #expect(!read.fits(plan()), "kind \(byte)")
        }
    }


    @Test("fits asks about the encoding before it takes the free-slot shortcut")
    func fitsChecksTheEncodingFirst() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(FSLayout.objectSize), alignment: 8
        )
        defer { raw.deallocate() }

        // A genuinely free slot, which every disk this build formats is full of.
        FSObject().write(to: raw)
        #expect(FSObject(reading: raw).standing == .free)
        #expect(FSObject(reading: raw).fits(plan()))

        // The same slot claiming two hundred runs. `fits` used to return `true`
        // here: the free-slot shortcut came first, so the one field that had been
        // clamped was never asked about.
        raw.storeBytes(of: UInt8(200), toByteOffset: At.extents, as: UInt8.self)

        let read = FSObject(reading: raw)
        #expect(read.extents == UInt8(FSLayout.extentLimit))
        #expect(read.standing == .impossible)
        #expect(!read.fits(plan()))
    }


    @Test("an entry corpus: a length or a letter no name may hold is not a free slot")
    func entryCorpus() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(FSLayout.entrySize), alignment: 8
        )
        defer { raw.deallocate() }

        named("a.bin") { pointer, length in
            FSEntry(object: 7, name: pointer, length: length)!.write(to: raw)
        }

        #expect(FSEntry(reading: raw).standing == .named)
        #expect(FSEntry(reading: raw).object == 7)

        // Empty is free, and that is the only thing that is.
        FSEntry().write(to: raw)
        #expect(FSEntry(reading: raw).standing == .free)
        #expect(FSEntry(reading: raw).encodingValid)

        named("a.bin") { pointer, length in
            FSEntry(object: 7, name: pointer, length: length)!.write(to: raw)
        }

        // A length past the field. Clamped to zero so nothing reads a name off
        // the end, and no longer the same thing as an unused slot.
        for length in [UInt8(57), 100, 200, 255] {
            raw.storeBytes(of: length, toByteOffset: 4, as: UInt8.self)

            let read = FSEntry(reading: raw)
            #expect(read.isFree, "length \(length)")
            #expect(!read.encodingValid, "length \(length)")
            #expect(read.standing == .impossible, "length \(length)")
        }

        // A letter a name may not hold. The writer refuses all of these, so a
        // disk this build wrote has none, and the reader has to agree.
        for letter in [UInt8(ascii: "/"), UInt8(ascii: ":"), 0, 0x20, 0x7F, 0x80] {
            named("a.bin") { pointer, length in
                FSEntry(object: 7, name: pointer, length: length)!.write(to: raw)
            }
            raw.storeBytes(of: letter, toByteOffset: 8 + 1, as: UInt8.self)

            let read = FSEntry(reading: raw)
            #expect(!read.encodingValid, "letter \(letter)")
            #expect(read.standing == .impossible, "letter \(letter)")

            // And the writer would not have made one, which is the other half of
            // the same rule living in one place.
            var built = true
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 5) { room in
                room[0] = UInt8(ascii: "a"); room[1] = letter
                room[2] = UInt8(ascii: "b"); room[3] = UInt8(ascii: "i")
                room[4] = UInt8(ascii: "n")

                built = FSEntry(
                    object: 7, name: UnsafeRawPointer(room.baseAddress!), length: 5
                ) != nil
            }
            #expect(!built, "letter \(letter)")
        }
    }


    @Test("a record that is not one is never handed out again")
    func impossibleRecordsAreNotReused() {
        withDisk { fs, disk in
            guard let file = make(&fs, "victim.bin") else { return }

            // Behind the file system's back, and the cache dropped so that the
            // next read goes to the medium.
            disk.poke(UInt8(7), at: recordAt(fs, file) + At.kind)
            fs.dropCache()

            #expect(fs.object(file) == nil)
            #expect(fs.corrupted)

            // The slot the record sits in is never handed out. It cannot be:
            // nothing is written to this volume any more.
            #expect(heldStill(&fs, disk))
        }
    }


    @Test("a table walk does not hand out the slot of a record it cannot read")
    func allocateSkipsImpossibleSlots() {
        withDisk { fs, disk in
            guard let file = make(&fs, "victim.bin") else { return }

            disk.poke(UInt8(7), at: recordAt(fs, file) + At.kind)
            fs.dropCache()

            #expect(fs.begin() == .ok)

            // Asked of the allocator itself, because that is the loop that used
            // to read the clamp as an answer: `free.kind == .free` was true for
            // this slot, so the next `create` was given it.
            let taken = fs.allocateObject(kind: .file)
            #expect(taken.refusal == .quarantined)
            #expect(taken.object == nil)

            fs.abort()
            #expect(fs.corrupted)
        }
    }


    // MARK: - A read error is not permission

    @Test("an unreadable folder is not an empty folder")
    func aReadErrorIsNotAMiss() {
        withDisk { fs, disk in
            guard make(&fs, "a.bin") != nil else { return }

            fs.dropCache()
            disk.failAfter(1)

            var refusal = FSStatus.ok
            named("a.bin") { pointer, length in
                refusal = fs.lookup(pointer, length: length, in: FSLayout.rootObject).refusal
            }

            // `notFound` is the one refusal that means "there is no such name",
            // and it is what authorises writing one.
            #expect(refusal == .deviceFailed)

            disk.recover()
            fs.dropCache()

            var found: UInt32? = nil
            named("a.bin") { pointer, length in
                found = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            #expect(found != nil)
        }
    }


    @Test("an unreadable folder does not report itself empty")
    func aReadErrorIsNotEmptiness() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder),
                  make(&fs, "a.txt", in: folder) != nil
            else { return }

            #expect(fs.emptiness(of: folder) == .notEmpty)

            fs.dropCache()
            disk.failAfter(1)

            // It used to answer `true` here, and `remove` reads that as
            // permission to free a folder with things still in it.
            #expect(fs.emptiness(of: folder) == .deviceFailed)

            disk.recover()
        }
    }


    /// How many entries in `folder` are named `name`.
    ///
    /// A raw walk, because the question is whether the folder holds the name
    /// twice and `lookup` answers with the first one it meets.
    private func timesNamed(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        in folder: UInt32
    ) -> Int {
        var seen = 0

        named(name) { pointer, length in
            _ = fs.forEachEntry(in: folder) { entry, _, _ in
                if entry.matches(pointer, length: length) { seen += 1 }
            }
        }

        return seen
    }


    @Test("no read failure lets a name be written twice")
    func noFaultAuthorisesADuplicate() {
        var refused = 0

        for stop in 1...24 {
            let disk  = MemoryDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format")
                return
            }
            guard make(&fs, "a.bin") != nil else { return }

            // Transient, and it has to be. A device that stays broken refuses the
            // write as well, so a wrong decision never reaches the medium and this
            // probe could not see it.
            fs.dropCache()
            disk.refuseNext(stop)

            var status = FSStatus.ok
            named("a.bin") { pointer, length in
                status = fs.create(
                    pointer, length: length, kind: .file, in: FSLayout.rootObject
                ).status
            }

            disk.recover()
            fs.dropCache()

            #expect(status != .ok, "stop \(stop): a name that was there was made again")
            if status != .ok { refused += 1 }

            #expect(
                timesNamed(&fs, "a.bin", in: FSLayout.rootObject) == 1,
                "stop \(stop): the folder holds the name more than once"
            )
        }

        #expect(refused == 24)
    }


    @Test("a name targeting the first object past the table holds the volume")
    func targetPastTheTableCannotAuthoriseACreate() {
        withDisk { fs, disk in
            guard make(&fs, "duplicate.bin") != nil else {
                return
            }

            guard let block = folderAt(&fs, FSLayout.rootObject) else {
                Issue.record("root directory")
                return
            }

            disk.poke(fs.plan.objectCount, at: block)
            fs.dropCache()

            let writes = disk.writes
            var lookup = FSStatus.ok
            var created = FSStatus.ok

            named("duplicate.bin") { pointer, length in
                lookup = fs.lookup(pointer, length: length, in: FSLayout.rootObject).refusal
                created = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject).status
            }

            #expect(lookup == .quarantined)
            #expect(created == .quarantined)
            #expect(fs.corrupted)
            #expect(disk.writes == writes)
        }
    }


    @Test("a mutation preserves a busy begin refusal")
    func createPreservesBusyBegin() {
        withDisk { fs, _ in
            #expect(fs.begin() == .ok)

            named("blocked.bin") { pointer, length in
                #expect(
                    fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject).status == .busy
                )
            }

            fs.abort()
        }
    }


    @Test("room and free-space answers retain a read failure")
    func capacityAnswersKeepTheirStatus() {
        withDisk { fs, disk in
            let free = fs.freeBlocksResult()
            #expect(free.status == .ok)
            #expect(free.value > 0)

            let room = fs.roomResult(of: FSLayout.rootObject)
            #expect(room.status == .ok)
            #expect(room.value != nil)

            fs.dropCache()
            disk.failAfter(1)

            #expect(fs.freeBlocksResult().status == .deviceFailed)
            #expect(fs.roomResult(of: FSLayout.rootObject).status == .deviceFailed)
        }
    }


    @Test("no read failure lets a folder with something in it be removed")
    func noFaultAuthorisesARemoval() {
        for stop in 1...24 {
            let disk  = MemoryDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format")
                return
            }

            guard let folder = make(&fs, "docs", kind: .folder),
                  make(&fs, "a.txt", in: folder) != nil
            else { return }

            fs.dropCache()
            disk.refuseNext(stop)

            var status = FSStatus.ok
            named("docs") { pointer, length in
                status = fs.remove(pointer, length: length, from: FSLayout.rootObject)
            }

            disk.recover()
            fs.dropCache()

            #expect(status != .ok, "stop \(stop): a folder with something in it was removed")

            // And it is all still there, whichever read failed.
            var again: UInt32? = nil
            named("docs") { pointer, length in
                again = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }

            #expect(again == folder, "stop \(stop)")
            #expect(fs.emptiness(of: folder) == .notEmpty, "stop \(stop)")
        }
    }


    // MARK: - The listing

    @Test("a listing whose entry points at a free slot is an error, not a name")
    func listingRefusesADeadTarget() {
        withDisk { fs, disk in
            guard let file = make(&fs, "a.bin") else { return }

            // The record freed behind the file system's back, which is a state
            // no transaction of this build leaves: `remove` stages the entry and
            // the freed record together.
            disk.poke(UInt8(0), at: recordAt(fs, file) + At.kind)
            fs.dropCache()

            let room = UnsafeMutableRawPointer.allocate(
                byteCount: FSListEntry.width * 4, alignment: 8
            )
            defer { room.deallocate() }
            room.initializeMemory(as: UInt8.self, repeating: 0xEE, count: FSListEntry.width * 4)

            let batch = fs.entries(
                from: 0, in: FSLayout.rootObject, into: room, capacity: 4
            )

            #expect(batch.status == .quarantined)
            #expect(batch.count == 0)
            #expect(!batch.eof)
            #expect(fs.corrupted)

            // And nothing was invented in the caller's window. It used to receive
            // the name with a kind of `.free`, which is a listing entry for a
            // thing that is not there.
            for byte in 0..<FSListEntry.width {
                #expect(
                    room.loadUnaligned(fromByteOffset: byte, as: UInt8.self) == 0xEE,
                    "byte \(byte) of the window was written"
                )
            }
        }
    }


    @Test("a listing whose entry points somewhere else is an error")
    func listingRefusesAStrayTarget() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder),
                  let file = make(&fs, "a.bin", in: folder)
            else { return }

            // The file says it lives in the root while the folder names it. One
            // of the two is lying and nothing here can say which.
            disk.poke(FSLayout.rootObject, at: recordAt(fs, file) + At.parent)
            fs.dropCache()

            let room = UnsafeMutableRawPointer.allocate(
                byteCount: FSListEntry.width * 4, alignment: 8
            )
            defer { room.deallocate() }

            let batch = fs.entries(from: 0, in: folder, into: room, capacity: 4)

            #expect(batch.status == .quarantined)
            #expect(batch.count == 0)
            #expect(fs.corrupted)
        }
    }


    @Test("a folder slot whose bytes are not an entry holds the volume")
    func brokenEntryHoldsTheVolume() {
        withDisk { fs, disk in
            guard make(&fs, "a.bin") != nil,
                  let block = folderAt(&fs, FSLayout.rootObject)
            else { return }

            // A length past the field, in the entry that is really there. It used
            // to read as an unused slot, so `link` would lay a name over it.
            disk.poke(UInt8(200), at: block + 4)
            fs.dropCache()

            var refusal = FSStatus.ok
            named("a.bin") { pointer, length in
                refusal = fs.lookup(pointer, length: length, in: FSLayout.rootObject).refusal
            }

            #expect(refusal == .quarantined)
            #expect(fs.corrupted)
            #expect(heldStill(&fs, disk))
        }
    }


    // MARK: - Loops, and rooms that are not rooms

    @Test("an object that is its own parent holds the volume")
    func selfParentHoldsTheVolume() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder) else { return }

            disk.poke(folder, at: recordAt(fs, folder) + At.parent)
            fs.dropCache()

            // Refused at the one door every record comes through, so nothing
            // downstream has to know about it.
            #expect(fs.object(folder) == nil)
            #expect(fs.corrupted)
            #expect(heldStill(&fs, disk))
        }
    }


    @Test("two folders that are each other's parent hold the volume")
    func aLongerLoopHoldsTheVolume() {
        withDisk { fs, disk in
            guard let first = make(&fs, "one", kind: .folder),
                  let second = make(&fs, "two", kind: .folder)
            else { return }

            disk.poke(second, at: recordAt(fs, first) + At.parent)
            disk.poke(first,  at: recordAt(fs, second) + At.parent)
            fs.dropCache()

            // Neither record is impossible on its own, so the loop is only
            // visible to a walk. The walk is bounded, and running off the end of
            // it is now a finding rather than a shrug.
            #expect(fs.depth(of: first) == nil)
            #expect(fs.corrupted)

            let reaches = fs.contains(first, within: FSLayout.rootObject)
            #expect(!reaches)
            #expect(heldStill(&fs, disk))
        }
    }


    @Test("a record charged to something that is not a container holds the volume")
    func quotaContradictionHoldsTheVolume() {
        withDisk { fs, disk in
            guard let host = make(&fs, "host.bin"),
                  let guest = make(&fs, "guest.bin")
            else { return }

            // A file charged to a file. Every quota comparison downstream reads
            // and writes `quota` and `used` on a record that has neither.
            disk.poke(host, at: recordAt(fs, guest) + At.container)
            fs.dropCache()

            #expect(fs.charged(guest) == nil)
            #expect(fs.corrupted)
            #expect(heldStill(&fs, disk))
        }
    }


    @Test("a container that has spent more than it was given is not believed")
    func spentMoreThanGivenIsRefused() {
        withDisk { fs, disk in
            guard let inner = make(&fs, "inner", kind: .container) else { return }

            #expect(fs.room(of: inner) != nil)

            // Nothing writing this disk can make one: every charge is checked
            // against the room left first.
            disk.poke(UInt32(4),  at: recordAt(fs, inner) + At.quota)
            disk.poke(UInt32(99), at: recordAt(fs, inner) + At.used)
            fs.dropCache()

            #expect(fs.object(inner) == nil)
            #expect(fs.room(of: inner) == nil)
            #expect(fs.corrupted)
        }
    }


    // MARK: - How deep a tree may be

    @Test("the nesting limit is enforced where the depth grows")
    func createEnforcesTheNestingLimit() {
        withDisk { fs, _ in
            var here  = FSLayout.rootObject
            var depth = 0

            // Down to the limit, one folder at a time, and the refusal is the
            // limit rather than the disk.
            while depth < FileSystem<MemoryDisk>.nestingLimit + 4 {
                var made: (status: FSStatus, object: UInt32) = (.ok, 0)

                named("d") { pointer, length in
                    made = fs.create(pointer, length: length, kind: .folder, in: here)
                }

                guard made.status == .ok else {
                    #expect(made.status == .tooDeep, "at depth \(depth)")
                    break
                }

                here   = made.object
                depth += 1
            }

            // The deepest object is at `nestingLimit - 1`, so a walk up from it
            // has room to reach the root inside the bound every check uses.
            #expect(depth == FileSystem<MemoryDisk>.nestingLimit - 1)
            #expect(fs.depth(of: here) == depth)
            #expect(!fs.corrupted)

            // And the walk from the deepest thing still answers, which is the
            // point of enforcing the limit one short of it.
            let reaches = fs.contains(here, within: FSLayout.rootObject)
            #expect(reaches)
        }
    }


    @Test("relocating cannot push a subtree past the limit")
    func relocateEnforcesTheNestingLimit() {
        withDisk { fs, _ in
            guard let source = make(&fs, "source", kind: .folder),
                  let deeper = make(&fs, "deeper", kind: .folder),
                  let full = make(&fs, "full", kind: .folder),
                  make(&fs, "child.bin", in: source) != nil,
                  make(&fs, "kept.bin", in: full) != nil
            else { return }

            // A file has no subtree, so it may go anywhere inside the limit.
            var moved = FSStatus.ok

            named("child.bin") { pointer, length in
                moved = fs.relocate(
                    pointer, length: length, from: source, to: deeper,
                    as: pointer, length: length
                )
            }
            #expect(moved == .ok)

            // An empty folder has no subtree either, and `source` is one now.
            #expect(fs.emptiness(of: source) == .ok)

            named("source") { pointer, length in
                moved = fs.relocate(
                    pointer, length: length, from: FSLayout.rootObject, to: deeper,
                    as: pointer, length: length
                )
            }
            #expect(moved == .ok)

            // A folder with something in it moving *deeper* is refused: see the
            // second of the two rules on `relocate`.
            #expect(fs.emptiness(of: full) == .notEmpty)

            named("full") { pointer, length in
                moved = fs.relocate(
                    pointer, length: length, from: FSLayout.rootObject, to: deeper,
                    as: pointer, length: length
                )
            }
            #expect(moved == .tooDeep)

            // Sideways is allowed, because the rule is about getting deeper: two
            // folders one step from the root, and a non-empty folder moving
            // between them keeps every descendant at the depth it had.
            guard let homeA = make(&fs, "homeA", kind: .folder),
                  let homeB = make(&fs, "homeB", kind: .folder),
                  let inner = make(&fs, "inner", kind: .folder, in: homeA),
                  make(&fs, "leaf.bin", in: inner) != nil
            else { return }

            #expect(fs.emptiness(of: inner) == .notEmpty)

            named("inner") { pointer, length in
                moved = fs.relocate(
                    pointer, length: length, from: homeA, to: homeB,
                    as: pointer, length: length
                )
            }
            #expect(moved == .ok)

            // And shallower, which every rule here allows.
            named("inner") { pointer, length in
                moved = fs.relocate(
                    pointer, length: length, from: homeB, to: FSLayout.rootObject,
                    as: pointer, length: length
                )
            }
            #expect(moved == .ok)

            #expect(!fs.corrupted)
        }
    }


    // MARK: - What a finding nobody can put right does

    @Test("a finding no repair can derive holds the volume, repairable or not")
    func unfixableFindingsHoldTheVolume() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder) else { return }

            // Blocks nobody owns, which *is* repairable: the map is a function of
            // the table, so it can be recomputed.
            #expect(fs.begin() == .ok)
            let orphan = fs.allocateRun(4)
            #expect(fs.commit() == .ok)
            #expect(orphan.refusal == .ok)

            // And a self-parented folder, which nothing can derive the answer to.
            disk.poke(folder, at: recordAt(fs, folder) + At.parent)
            fs.dropCache()

            let findings = fs.putRight()

            #expect(findings.selfParented > 0)
            #expect(findings.unfixable)

            // Both halves. It used to repair the map and leave the volume
            // writable, because the quarantine was inside the branch that is only
            // taken when there is nothing to repair.
            #expect(fs.corrupted)
            #expect(!findings.mapMended)
            #expect(heldStill(&fs, disk))
        }
    }


    @Test("a scan counts a folder slot that is not an entry")
    func scanCountsBrokenEntries() {
        withDisk { fs, disk in
            guard make(&fs, "a.bin") != nil,
                  let block = folderAt(&fs, FSLayout.rootObject)
            else { return }

            disk.poke(UInt8(200), at: block + 4)
            fs.dropCache()

            let findings = fs.scan(.everything)

            #expect(findings.brokenEntries == 1)
            #expect(findings.damaged)
            #expect(findings.unfixable)
            #expect(fs.corrupted)
        }
    }
}
