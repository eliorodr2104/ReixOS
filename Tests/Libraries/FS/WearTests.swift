//
//  WearTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.

import Testing
import ReixABI
@testable import ReixFS

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
