//
//  MaintenanceTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// Shortening, moving, renaming, and putting the disk back together.
///
/// These are the operations that *undo* things, which is why they get their own
/// suite: an operation that adds is wrong when it does nothing, and an operation
/// that removes is wrong when it does too much.
@Suite("Maintenance")
struct MaintenanceTests {

    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
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

        body(&fs, disk)
    }

    private func name(_ text: StaticString) -> (UnsafeRawPointer, Int) {
        (UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        _ kind: FSKind = .file,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32 {
        let n = name(text)
        return fs.create(n.0, length: n.1, kind: kind, in: folder).object
    }

    private func fill(
        _ fs: inout FileSystem<MemoryDisk>,
        _ file: UInt32,
        _ bytes: Int,
        byte: UInt8 = 0x5A,
        replacing: Bool = false
    ) -> FSStatus {
        let out = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { out.deallocate() }
        out.initializeMemory(as: UInt8.self, repeating: byte, count: bytes)

        return fs.write(
            file, at: 0, from: UnsafeRawPointer(out),
            count: UInt64(bytes), replacing: replacing
        ).status
    }

    private func size(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32) -> UInt64 {
        fs.object(file)?.size ?? UInt64.max
    }

    private func blocks(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32) -> UInt32 {
        fs.object(file)?.blocks ?? UInt32.max
    }

    private func free(_ fs: inout FileSystem<MemoryDisk>) -> UInt32 { fs.freeBlocks() }

    /// What the container thinks it is using, which is a different fact from
    /// what the block map thinks is taken. Both have to come back.
    private func used(_ fs: inout FileSystem<MemoryDisk>) -> UInt32 {
        fs.room(of: FSLayout.rootObject)?.used ?? UInt32.max
    }

    private func find(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        let n = name(text)
        return fs.lookup(n.0, length: n.1, in: folder)
    }

    private func move(
        _ fs: inout FileSystem<MemoryDisk>,
        _ from: StaticString,
        in folder: UInt32,
        to target: UInt32,
        as to: StaticString
    ) -> FSStatus {
        let a = name(from), b = name(to)
        return fs.relocate(a.0, length: a.1, from: folder, to: target, as: b.0, length: b.1)
    }


    private func inside(
        _ fs: inout FileSystem<MemoryDisk>,
        _ object: UInt32,
        _ root: UInt32
    ) -> Bool {
        fs.contains(object, within: root)
    }

    private func cut(
        _ fs: inout FileSystem<MemoryDisk>,
        _ file: UInt32,
        to bytes: UInt64 = 0
    ) -> FSStatus {
        fs.truncate(file, to: bytes)
    }

    private func extents(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32) -> UInt8 {
        fs.object(file)?.extents ?? 0
    }

    private func parent(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32) -> UInt32 {
        fs.object(file)?.parent ?? UInt32.max
    }

    private func inspect(_ fs: inout FileSystem<MemoryDisk>) -> FileSystem<MemoryDisk>.Findings {
        fs.check()
    }

    private func read(
        _ fs: inout FileSystem<MemoryDisk>,
        _ file: UInt32,
        _ into: UnsafeMutableRawPointer,
        _ count: UInt64
    ) -> UInt64 {
        fs.read(file, at: 0, into: into, count: count).bytes
    }


    // MARK: - Shortening

    @Test("a replacing write leaves nothing of what was longer")
    func replacingShortens() {
        withFileSystem { fs, _ in
            let file = make(&fs, "note.txt")

            #expect(fill(&fs, file, 9000, byte: 0x11) == .ok)
            #expect(size(&fs, file) == 9000)
            #expect(blocks(&fs, file) == 3)

            #expect(fill(&fs, file, 4, byte: 0x22, replacing: true) == .ok)
            #expect(size(&fs, file) == 4)

            // And the blocks are back, not merely unreferenced.
            #expect(blocks(&fs, file) == 1)

            let back = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
            defer { back.deallocate() }

            #expect(read(&fs, file, back, 32) == 4)
        }
    }


    @Test("a plain write over a shorter stretch keeps the tail, as it should")
    func plainWriteKeepsTheTail() {
        withFileSystem { fs, _ in
            let file = make(&fs, "note.txt")

            #expect(fill(&fs, file, 100, byte: 0xAA) == .ok)
            #expect(fill(&fs, file, 4, byte: 0xBB) == .ok)

            // Seeking and writing four bytes is not "the file now says four
            // bytes", and this is the difference the flag exists for.
            #expect(size(&fs, file) == 100)
        }
    }


    @Test("shortening gives the blocks back to the container that paid")
    func shorteningRefunds() {
        withFileSystem { fs, _ in
            let before = free(&fs)
            let file   = make(&fs, "big.bin")

            #expect(fill(&fs, file, 40960) == .ok)
            let full  = free(&fs)
            let owing = used(&fs)
            #expect(full < before - 5)
            #expect(owing >= 10)

            #expect(cut(&fs, file) == .ok)
            #expect(size(&fs, file) == 0)
            #expect(blocks(&fs, file) == 0)
            #expect(free(&fs) > full)

            // The container's own account, not just the map: forgetting this
            // one leaves a container that cannot use room nothing is holding.
            #expect(used(&fs) == owing - 10)
        }
    }


    @Test("a run cut in the middle keeps its head and loses its tail")
    func partialRunSurvives() {
        withFileSystem { fs, _ in
            let file = make(&fs, "run.bin")

            #expect(fill(&fs, file, 8 * 4096) == .ok)
            #expect(blocks(&fs, file) == 8)
            #expect(extents(&fs, file) == 1)

            let taken = free(&fs)

            #expect(cut(&fs, file, to: UInt64(3 * 4096 + 1)) == .ok)

            // Four of the eight go back to the map. The record saying four is
            // not the same claim: a record can say four while the map still
            // holds eight, and that is exactly the leak worth catching.
            #expect(free(&fs) == taken + 4)
            #expect(blocks(&fs, file) == 4)
            #expect(extents(&fs, file) == 1)
            #expect(size(&fs, file) == UInt64(3 * 4096 + 1))
        }
    }


    // MARK: - Moving and renaming

    @Test("a rename in place changes the name and nothing else")
    func rename() {
        withFileSystem { fs, _ in
            let file = make(&fs, "old.txt")
            #expect(fill(&fs, file, 500) == .ok)

            #expect(move(&fs, "old.txt", in: FSLayout.rootObject,
                         to: FSLayout.rootObject, as: "new.txt") == .ok)

            #expect(find(&fs, "old.txt") == nil)
            #expect(find(&fs, "new.txt") == file)
            #expect(size(&fs, file) == 500)
        }
    }


    @Test("a move into another folder changes where it lives")
    func moveBetweenFolders() {
        withFileSystem { fs, _ in
            let docs = make(&fs, "docs", .folder)
            let file = make(&fs, "x.txt")

            #expect(move(&fs, "x.txt", in: FSLayout.rootObject, to: docs, as: "x.txt") == .ok)

            #expect(find(&fs, "x.txt") == nil)
            #expect(find(&fs, "x.txt", in: docs) == file)
            #expect(parent(&fs, file) == docs)
            #expect(inside(&fs, file, docs))
        }
    }


    @Test("a folder cannot be moved inside itself")
    func noCycles() {
        withFileSystem { fs, _ in
            let outer = make(&fs, "outer", .folder)
            let inner = make(&fs, "inner", .folder, in: outer)

            #expect(move(&fs, "outer", in: FSLayout.rootObject, to: inner, as: "outer") == .wrongKind)
            #expect(move(&fs, "outer", in: FSLayout.rootObject, to: outer, as: "outer") == .wrongKind)

            // The tree still ends, which is the thing that was being protected.
            #expect(inside(&fs, inner, FSLayout.rootObject))
        }
    }


    @Test("a move across containers is refused rather than done halfway")
    func noCrossingContainers() {
        withFileSystem { fs, _ in
            let alpha = fs.createContainer(name("alpha").0, length: 5, quota: 32,
                                           in: FSLayout.rootObject).object
            let beta  = fs.createContainer(name("beta").0, length: 4, quota: 32,
                                           in: FSLayout.rootObject).object

            _ = make(&fs, "x.txt", .file, in: alpha)

            #expect(move(&fs, "x.txt", in: alpha, to: beta, as: "x.txt") == .wrongKind)
            #expect(find(&fs, "x.txt", in: alpha) != nil)
            #expect(find(&fs, "x.txt", in: beta) == nil)
        }
    }


    @Test("a name already taken stops the move, leaving both where they were")
    func collision() {
        withFileSystem { fs, _ in
            let a = make(&fs, "a.txt")
            let b = make(&fs, "b.txt")

            #expect(move(&fs, "a.txt", in: FSLayout.rootObject,
                         to: FSLayout.rootObject, as: "b.txt") == .exists)

            #expect(find(&fs, "a.txt") == a)
            #expect(find(&fs, "b.txt") == b)
        }
    }


    // MARK: - The machine's name

    @Test("the machine can be renamed, and refuses a name that is not one")
    func machineName() {
        withFileSystem { fs, _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
            defer { buffer.deallocate() }

            func current() -> String {
                let length = fs.machineName(into: buffer)
                let bytes  = buffer.assumingMemoryBound(to: UInt8.self)

                var text = ""
                for index in 0..<length { text.append(Character(UnicodeScalar(bytes[index]))) }
                return text
            }

            #expect(current() == "reix")

            let good = name("laboratorio")
            #expect(fs.setMachineName(good.0, length: good.1) == .ok)
            #expect(current() == "laboratorio")

            // A name with a separator in it could lie about where things live.
            let bad = name("a/b")
            #expect(fs.setMachineName(bad.0, length: bad.1) == .badName)

            let crossing = name("a::b")
            #expect(fs.setMachineName(crossing.0, length: crossing.1) == .badName)

            #expect(current() == "laboratorio")
        }
    }


    // MARK: - Putting it back together

    @Test("a clean disk needs nothing doing to it")
    func checkFindsNothing() {
        withFileSystem { fs, _ in
            let file = make(&fs, "a.bin")
            #expect(fill(&fs, file, 20000) == .ok)

            let findings = inspect(&fs)

            #expect(findings.reclaimable == 0)
            #expect(findings.ownedButFree == 0)
            #expect(!findings.changed)
        }
    }


    @Test("blocks nobody owns are found and given back")
    func leakedBlocksComeBack() {
        withFileSystem { fs, _ in
            let before = free(&fs)

            // Exactly the shape of a machine dying between taking the blocks
            // and writing the record that owns them.
            guard let orphan = fs.allocateRun(6) else {
                Issue.record("the blocks were not allocated")
                return
            }
            #expect(free(&fs) == before - 6)

            let findings = inspect(&fs)

            #expect(findings.reclaimable == 6)
            #expect(findings.ownedButFree == 0)
            #expect(free(&fs) == before)
            #expect(orphan >= 18)
        }
    }


    @Test("blocks an object owns that the map called free are taken back")
    func doubleBookingIsClosed() {
        withFileSystem { fs, _ in
            let file = make(&fs, "a.bin")
            #expect(fill(&fs, file, 12000) == .ok)

            guard let record = fs.object(file) else { return }
            let run = record.runs[0]

            // The map forgets a block an object is using. One more allocation
            // and it would have been handed to somebody else as well.
            fs.releaseRun(start: run.start, count: 1)

            let findings = inspect(&fs)

            #expect(findings.ownedButFree == 1)
            #expect(findings.changed)

            // And it is right afterwards.
            #expect(!inspect(&fs).changed)
        }
    }
}


/// Keeping files in one piece, and finding slots without walking the disk.
///
/// Both of these are about a system that gets slower the more it is used, which
/// is a kind of wrong that no single operation ever fails at.
@Suite("Wear")
struct WearTests {

    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
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

        body(&fs, disk)
    }

    private func name(_ text: StaticString) -> (UnsafeRawPointer, Int) {
        (UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32 {
        let n = name(text)
        return fs.create(n.0, length: n.1, kind: .file, in: folder).object
    }

    private func grow(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32, by bytes: Int, at offset: UInt64) -> FSStatus {
        let out = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { out.deallocate() }
        out.initializeMemory(as: UInt8.self, repeating: 0x33, count: bytes)

        return fs.write(file, at: offset, from: UnsafeRawPointer(out), count: UInt64(bytes)).status
    }

    private func extents(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32) -> UInt8 {
        fs.object(file)?.extents ?? 0
    }

    private func squash(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32) -> FSStatus {
        fs.compact(file)
    }

    private func drop(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        _ folder: UInt32
    ) -> FSStatus {
        let n = name(text)
        return fs.remove(n.0, length: n.1, from: folder)
    }

    private func readByte(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32, at offset: UInt64) -> UInt8 {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 8)
        defer { buffer.deallocate() }

        guard fs.read(file, at: offset, into: buffer, count: 1).bytes == 1 else { return 0 }

        return buffer.loadUnaligned(as: UInt8.self)
    }


    @Test("a file growing on its own stays in one piece")
    func growthStaysWhole() {
        withFileSystem { fs, _ in
            let one = make(&fs, "one.bin")

            for step in 0..<8 {
                #expect(grow(&fs, one, by: 4096, at: UInt64(step) * 4096) == .ok)
            }

            // Eight separate writes, one extent: each asks for the block after
            // its own last one and gets it.
            #expect(extents(&fs, one) == 1)
        }
    }


    @Test("two files growing in step do break up, which is what compaction is for")
    func alternatingGrowthFragments() {
        withFileSystem { fs, _ in
            let one = make(&fs, "one.bin")
            let two = make(&fs, "two.bin")

            // Strict alternation: each file's next block is taken by the other
            // between its writes, so neither can stay whole and no allocator
            // that hands out one block at a time could make it otherwise.
            for step in 0..<6 {
                #expect(grow(&fs, one, by: 4096, at: UInt64(step) * 4096) == .ok)
                #expect(grow(&fs, two, by: 4096, at: UInt64(step) * 4096) == .ok)
            }

            #expect(extents(&fs, one) > 1)

            // Recorded here rather than assumed: this is the case compaction
            // exists for, and the test below is the one that fixes it.
            #expect(squash(&fs, one) == .ok)
            #expect(extents(&fs, one) == 1)
        }
    }


    @Test("a file reclaims the room beside it when it comes free")
    func growthTakesBackItsNeighbour() {
        withFileSystem { fs, _ in
            let one = make(&fs, "one.bin")
            let two = make(&fs, "two.bin")

            #expect(grow(&fs, one, by: 2 * 4096, at: 0) == .ok)
            #expect(grow(&fs, two, by: 2 * 4096, at: 0) == .ok)
            #expect(extents(&fs, one) == 1)

            // The blocks immediately after `one` belong to `two`, and then
            // stop belonging to anybody.
            #expect(drop(&fs, "two.bin", FSLayout.rootObject) == .ok)

            #expect(grow(&fs, one, by: 2 * 4096, at: 2 * 4096) == .ok)

            // Asking for the block after its own last one is what finds them
            // again. Taking whatever came next in the map would have put the
            // file in two pieces with a hole between them.
            #expect(extents(&fs, one) == 1)
        }
    }


    @Test("a file already in one piece is not copied about for nothing")
    func compactingAWholeFileIsFree() {
        withFileSystem { fs, disk in
            let file = make(&fs, "whole.bin")
            #expect(grow(&fs, file, by: 4 * 4096, at: 0) == .ok)
            #expect(extents(&fs, file) == 1)

            let before = disk.reads + disk.writes
            #expect(squash(&fs, file) == .ok)
            let cost = disk.reads + disk.writes - before

            // One read of the record to see there is nothing to do, and no copy.
            #expect(cost <= 2)
            #expect(extents(&fs, file) == 1)
        }
    }


    @Test("a file broken into pieces can be put back into one")
    func compaction() {
        withFileSystem { fs, _ in
            let victim  = make(&fs, "victim.bin")
            let spoiler = make(&fs, "spoiler.bin")

            // Deliberately alternated so the victim ends up scattered.
            for step in 0..<6 {
                #expect(grow(&fs, victim, by: 4096, at: UInt64(step) * 4096) == .ok)
                #expect(grow(&fs, spoiler, by: 4096, at: UInt64(step) * 4096) == .ok)
            }

            // Its contents before, at a place that will move.
            let sample = readByte(&fs, victim, at: 5 * 4096 + 7)

            #expect(squash(&fs, victim) == .ok)
            #expect(extents(&fs, victim) == 1)

            // Same bytes afterwards, which is the whole claim.
            #expect(readByte(&fs, victim, at: 5 * 4096 + 7) == sample)
            #expect(fs.object(victim)?.size == UInt64(6 * 4096))

            // And it is still whole after doing it again to a file already whole.
            #expect(squash(&fs, victim) == .ok)
            #expect(extents(&fs, victim) == 1)
        }
    }


    @Test("finding a free slot costs the same on a full table as on an empty one")
    func slotsAreFoundNearby() {
        withFileSystem { fs, disk in

            for _ in 0..<8 { _ = fs.allocateObject(kind: .file) }

            let earlyStart = disk.reads
            _ = fs.allocateObject(kind: .file)
            let early = disk.reads - earlyStart

            for _ in 0..<600 { _ = fs.allocateObject(kind: .file) }

            let lateStart = disk.reads
            _ = fs.allocateObject(kind: .file)
            let late = disk.reads - lateStart

            // A number would be a guess; the property is that it did not grow.
            // Searching the table from the front would make the six-hundredth
            // slot cost ten table reads where the first cost one, and the gap
            // widens with every disk bigger than this one.
            #expect(late <= early)
        }
    }


    @Test("a folder costs one read per sixty-four names, and that is written down")
    func foldersScan() {
        withFileSystem { fs, disk in

            func makeNumbered(_ index: Int) {
                var text = InlineArray<8, UInt8>(repeating: 0)
                text[0] = UInt8(ascii: "f")
                text[1] = UInt8(48 + (index / 100) % 10)
                text[2] = UInt8(48 + (index / 10) % 10)
                text[3] = UInt8(48 + index % 10)

                _ = withUnsafePointer(to: &text) { pointer in
                    fs.create(
                        UnsafeRawPointer(pointer), length: 4,
                        kind: .file, in: FSLayout.rootObject
                    )
                }
            }

            for index in 0..<8 { makeNumbered(index) }

            let smallStart = disk.reads
            makeNumbered(8)
            let small = disk.reads - smallStart

            for index in 9..<250 { makeNumbered(index) }

            let bigStart = disk.reads
            makeNumbered(250)
            let big = disk.reads - bigStart

            // It does grow, and this is the measurement rather than a claim
            // that it does not: a folder is searched by reading it, and 250
            // names are four blocks where 8 names are one. An index would fix
            // it and would cost the folder its order; nothing here needs that
            // yet, and when something does this test is where the number is.
            #expect(big > small)
            #expect(big <= small + 8)
        }
    }
}
