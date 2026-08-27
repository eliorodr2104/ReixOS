//
//  HostileRecordTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What a record is allowed to say about itself, and what a growth owes when it
/// cannot be finished.
///
/// Three things met here and each of them was a way of losing something quietly.
/// A record claiming two hundred runs was clamped to eight and then judged on its
/// merits, and eight is a number this format writes, so it passed. A growth that
/// ran out of extents part way gave back the blocks of its last allocation and
/// kept every one before it, charged to a container that would never see them
/// again. And an overwrite that changed a file without changing its length left
/// no trace that it had happened.
@Suite("Hostile records and unfinished growth")
struct HostileRecordTests {

    /// 16 MiB, the same as the image the Makefile makes.
    private static let sectors: UInt64 = 32768


    private func withFileSystem(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
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

        body(&fs, disk)
    }


    /// `f<nn>` as three bytes, so a fixture can make twenty files without
    /// twenty names.
    private func named(_ index: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        var name = InlineArray<8, UInt8>(repeating: 0)
        name[0] = UInt8(ascii: "f")
        name[1] = UInt8(0x30 + UInt8(index / 10 % 10))
        name[2] = UInt8(0x30 + UInt8(index % 10))

        name.span.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!), 3)
        }
    }

    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ index: Int
    ) -> UInt32? {
        var made: UInt32? = nil

        named(index) { pointer, length in
            let result = fs.create(
                pointer, length: length, kind: .file, in: FSLayout.rootObject
            )
            if result.status == .ok { made = result.object }
        }

        return made
    }


    // MARK: - What a record may claim

    @Test("a record claiming two hundred runs is refused, and holds the volume")
    func hostileExtentCount() {
        withFileSystem { fs, disk in
            guard let file = make(&fs, 1) else { Issue.record("create"); return }

            // Eight blocks, so the eight runs on the disk are real ones and every
            // other field of the record adds up. The only thing wrong with it is
            // going to be a number this format cannot mean.
            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Int(FSLayout.blockSize), alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(
                as: UInt8.self, repeating: 0x5A, count: Int(FSLayout.blockSize)
            )

            #expect(fs.write(
                file, at: 0, from: UnsafeRawPointer(payload),
                count: FSLayout.blockSize
            ).status == .ok)

            // Behind the file system's back, straight into the object table,
            // which is what a torn write or another system's disk looks like
            // from in here.
            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(file) * Int(FSLayout.objectSize)

            disk.poke(UInt8(200), at: at + 1)
            fs.dropCache()

            #expect(!fs.corrupted)

            // Refused as "there is nothing at that number", which every caller
            // already handles, and the volume held still on the way out.
            #expect(fs.object(file) == nil)
            #expect(fs.corrupted)

            // And nothing more is written to it.
            #expect(fs.write(
                file, at: 0, from: UnsafeRawPointer(payload), count: 8
            ).status != .ok)
        }
    }


    @Test("the clamp is still there, so nothing walks off the end of eight runs")
    func clampSurvives() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(FSLayout.objectSize), alignment: 8
        )
        defer { raw.deallocate() }
        raw.initializeMemory(
            as: UInt8.self, repeating: 0, count: Int(FSLayout.objectSize)
        )

        var record = FSObject(kind: .file, created: 1, container: FSLayout.rootObject)
        record.extents = 8
        record.write(to: raw)

        raw.storeBytes(of: UInt8(200), toByteOffset: 1, as: UInt8.self)

        let read = FSObject(reading: raw)

        #expect(read.extents == UInt8(FSLayout.extentLimit))
        #expect(!read.recordEncodingValid)

        // A record this format really wrote says so, and keeps saying so through
        // a round trip.
        var honest = FSObject(kind: .file, created: 1, container: FSLayout.rootObject)
        honest.extents = 3
        honest.write(to: raw)

        let back = FSObject(reading: raw)
        #expect(back.extents == 3)
        #expect(back.recordEncodingValid)
    }


    // MARK: - A growth that cannot be finished

    /// A disk with no free run longer than eight blocks: twenty-one files of
    /// eight blocks each, the rest of the disk filled, and then every other file
    /// removed.
    ///
    /// Ten islands of eight free blocks with a live file between each pair, which
    /// is what makes a growth take them one at a time and run out of extents part
    /// way through.
    private func fragmented(
        _ fs: inout FileSystem<MemoryDisk>
    ) -> UInt32? {

        let block  = Int(FSLayout.blockSize)
        let filler = UnsafeMutableRawPointer.allocate(byteCount: block * 100, alignment: 8)
        defer { filler.deallocate() }
        filler.initializeMemory(as: UInt8.self, repeating: 0x5A, count: block * 100)

        var first: UInt32? = nil

        for index in 0..<21 {
            guard let object = make(&fs, index) else { return nil }
            if index == 0 { first = object }

            guard fs.write(
                object, at: 0, from: UnsafeRawPointer(filler), count: UInt64(block * 8)
            ).status == .ok else { return nil }
        }

        guard let tail = make(&fs, 90) else { return nil }

        var at = UInt64(0)
        for chunk in [UInt64(block * 100), UInt64(block)] {
            while true {
                let written = fs.write(
                    tail, at: at, from: UnsafeRawPointer(filler), count: chunk
                )
                guard written.status == .ok, written.bytes > 0 else { break }
                at += written.bytes
            }
        }

        for index in stride(from: 1, to: 21, by: 2) {
            var gone = FSStatus.notFound
            named(index) { pointer, length in
                gone = fs.remove(pointer, length: length, from: FSLayout.rootObject)
            }
            guard gone == .ok else { return nil }
        }

        return first
    }


    @Test("a growth that runs out of extents gives back every block it took")
    func fragmentedGrowthRollsBack() {
        withFileSystem { fs, _ in
            guard let file = fragmented(&fs) else {
                Issue.record("the fragmented fixture could not be built")
                return
            }

            let freeBefore = fs.freeBlocks()
            let roomBefore = fs.room(of: FSLayout.rootObject)
            let before     = fs.object(file)

            #expect(freeBefore == 80)

            let block = Int(FSLayout.blockSize)
            let big   = UnsafeMutableRawPointer.allocate(byteCount: block * 80, alignment: 8)
            defer { big.deallocate() }
            big.initializeMemory(as: UInt8.self, repeating: 0x77, count: block * 80)

            // Eighty more blocks, and no run longer than eight to put them in.
            // It takes them an island at a time, joins each island onto the run
            // before it, and runs out of the eighth extent with sixteen still to
            // find.
            let grown = fs.write(
                file, at: UInt64(block * 8), from: UnsafeRawPointer(big),
                count: UInt64(block * 80)
            )

            #expect(grown.status == .tooFragmented)
            #expect(grown.bytes == 0)

            // The three things a half-rolled-back growth loses.
            #expect(fs.freeBlocks() == freeBefore)
            #expect(fs.room(of: FSLayout.rootObject)?.used == roomBefore?.used)
            #expect(fs.object(file)?.extents == before?.extents)
            #expect(fs.object(file)?.blocks == before?.blocks)

            // And the disk agrees with itself afterwards: no block is marked used
            // that nobody owns.
            fs.dropCache()

            let findings = fs.scan()
            #expect(findings.complete)
            #expect(findings.reclaimable == 0)
            #expect(findings.ownedButFree == 0)
            #expect(findings.wrongQuota == 0)
        }
    }


    @Test("a growth the disk cut short leaves the volume coherent, not quarantined")
    func deviceFailureNeedsNoQuarantine() {
        withFileSystem { fs, disk in
            guard let file = make(&fs, 1) else { Issue.record("create"); return }

            let block = Int(FSLayout.blockSize)
            let out   = UnsafeMutableRawPointer.allocate(byteCount: block * 2, alignment: 8)
            defer { out.deallocate() }
            out.initializeMemory(as: UInt8.self, repeating: 0x33, count: block * 2)

            let freeBefore = fs.freeBlocks()
            let roomBefore = fs.room(of: FSLayout.rootObject)

            #expect(!fs.corrupted)

            // The disk stops answering part way through the growth.
            //
            // This test used to expect a quarantine, and the reason it does not
            // any more is the point of the journal. Undoing the growth by hand was
            // itself a set of writes, so a disk that had stopped answering could
            // not be put right and the volume had to be held read-only. Now there
            // is nothing to undo: every claim the growth made is a staged image,
            // and a transaction that is not committed is a disk that never heard
            // of it. The failure is the disk's, not the format's.
            disk.failAfter(3)

            let written = fs.write(
                file, at: 0, from: UnsafeRawPointer(out), count: UInt64(block * 2)
            )

            #expect(written.status == .deviceFailed)
            #expect(!fs.corrupted)

            // And the numbers are as they were, without anybody having put them
            // back.
            disk.recover()
            fs.dropCache()

            #expect(fs.freeBlocks() == freeBefore)
            #expect(fs.room(of: FSLayout.rootObject)?.used == roomBefore?.used)

            // Still writable, because there is nothing wrong with the volume.
            #expect(fs.write(
                file, at: 0, from: UnsafeRawPointer(out), count: 8
            ).status == .ok)

            // And it agrees with itself.
            fs.dropCache()
            let findings = fs.scan()
            #expect(findings.complete)
            #expect(findings.reclaimable == 0)
            #expect(findings.ownedButFree == 0)
            #expect(findings.wrongQuota == 0)
        }
    }


    // MARK: - When a file was last changed

    @Test("an overwrite that changes no length still changes the time")
    func overwriteTouchesTime() {
        withFileSystem { fs, _ in
            guard let file = make(&fs, 1) else { Issue.record("create"); return }

            var payload = InlineArray<8, UInt8>(repeating: 0x11)

            fs.now = 1_000
            payload.span.withUnsafeBufferPointer { buffer in
                #expect(fs.write(
                    file, at: 0, from: UnsafeRawPointer(buffer.baseAddress!), count: 8
                ).status == .ok)
            }

            #expect(fs.object(file)?.modified == 1_000)

            // Same length, same place, different bytes. The file changed, so the
            // time it was last changed changed. It used to move only when the
            // file grew, which made this the one change that left no trace.
            fs.now = 2_000
            payload = InlineArray<8, UInt8>(repeating: 0x22)
            payload.span.withUnsafeBufferPointer { buffer in
                #expect(fs.write(
                    file, at: 0, from: UnsafeRawPointer(buffer.baseAddress!), count: 8
                ).status == .ok)
            }

            #expect(fs.object(file)?.modified == 2_000)

            // A write of nothing is not a change, so it does not claim to be one.
            fs.now = 3_000
            payload.span.withUnsafeBufferPointer { buffer in
                #expect(fs.write(
                    file, at: 0, from: UnsafeRawPointer(buffer.baseAddress!), count: 0
                ).status == .ok)
            }

            #expect(fs.object(file)?.modified == 2_000)

            // And a shorter replacement is a change too.
            fs.now = 4_000
            payload.span.withUnsafeBufferPointer { buffer in
                #expect(fs.write(
                    file, at: 0, from: UnsafeRawPointer(buffer.baseAddress!),
                    count: 4, replacing: true
                ).status == .ok)
            }

            #expect(fs.object(file)?.modified == 4_000)
            #expect(fs.object(file)?.size == 4)
        }
    }
}
