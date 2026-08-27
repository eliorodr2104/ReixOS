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
        return fs.lookup(n.0, length: n.1, in: folder).object
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
        fs.putRight()
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

            // Blocks marked used that no record owns. Not what a crash leaves any
            // more - the journal makes the claim and the record one act - but
            // still what a scan has to be able to find: a disk written by an
            // older build, or a bad block in the map.
            #expect(fs.begin() == .ok)
            let taken = fs.allocateRun(6)
            #expect(fs.commit() == .ok)

            guard case .taken(let orphan, _) = taken else {
                Issue.record("the blocks were not allocated: \(taken.refusal)")
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
            #expect(fs.begin() == .ok)
            let given = fs.releaseRun(start: run.start, count: 1)
            #expect(given == .ok)
            #expect(fs.commit() == .ok)

            let findings = inspect(&fs)

            #expect(findings.ownedButFree == 1)
            #expect(findings.changed)

            // And it is right afterwards.
            #expect(!inspect(&fs).changed)
        }
    }
}
