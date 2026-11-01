//
//  DataSumTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 01/11/2026.
//

import Testing
@testable import ReixFS
import ReixABI

/// The checksum of every block of file data, from both ends: what a reader gets
/// when a block is not what was last written there, and what a power cut in the
/// middle of an overwrite leaves for the next mount.
///
/// Every damage here is made with `poke` or `put`, behind the file system's back
/// and without counting as traffic, which is what rot, a lost write and a write
/// that landed somewhere else look like from in here.
@Suite("File data checks itself", .serialized)
struct DataSumTests {

    /// 16 MiB, the Makefile's image.
    private static let sectors: UInt64 = 32768

    private static let block = Int(FSLayout.blockSize)


    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
        let disk    = MemoryDisk(sectors: Self.sectors)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        body(&fs, disk)
    }

    /// Mounts what is on `disk` with a file system that has never seen it.
    private func remount(
        _ disk: MemoryDisk,
        _ body: (inout FileSystem<MemoryDisk>?, FSMount) -> Void
    ) {
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        let attempt = FileSystem.mount(disk, scratch: scratch)
        var mounted = attempt.disk
        body(&mounted, attempt.found)
    }


    // MARK: - What the reader gets

    @Test("a block that rotted is refused, and nothing past it is handed over")
    func rotIsRefused() {
        withFileSystem { fs, disk in
            let content = pattern(1, 6 * Self.block)
            guard let file = makeFile(&fs, "rot.bin", content) else { return }

            rot(disk, physical(&fs, file, 3), at: 77)

            // Six blocks: the pipelined read, which stops at the damaged block and
            // copies out nothing after it.
            let whole = readBack(&fs, file, count: content.count)
            #expect(whole.status == .damaged)
            #expect(whole.bytes == UInt64(3 * Self.block))
            #expect(Array(whole.data[0..<(3 * Self.block)]) == Array(content[0..<(3 * Self.block)]))
            #expect(whole.data[(3 * Self.block)...].allSatisfy { $0 == 0 })

            // One block: the plain loop, which refuses the same way.
            let one = readBack(&fs, file, at: UInt64(3 * Self.block), count: 10)
            #expect(one.status == .damaged)
            #expect(one.bytes == 0)

            // The blocks around it are whole, and the volume is not held for it.
            let next = readBack(&fs, file, at: UInt64(4 * Self.block), count: Self.block)
            #expect(next.status == .ok)
            #expect(next.data == Array(content[(4 * Self.block)..<(5 * Self.block)]))
            #expect(!fs.corrupted)
        }
    }


    @Test("a write the disk lost reads as damaged, not as the bytes before it")
    func lostWriteIsRefused() {
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "lost.bin", pattern(2, Self.block)) else { return }

            let home = physical(&fs, file, 0)
            let old  = disk.block(home)

            #expect(writeBytes(&fs, file, at: 0, pattern(3, Self.block)).status == .ok)

            // The device said yes and kept the old block.
            disk.put(old, block: home)

            #expect(readBack(&fs, file, count: Self.block).status == .damaged)
        }
    }


    @Test("damage is the file's, and the rest of the volume goes on being served")
    func damageStaysWithTheFile() {
        withFileSystem { fs, disk in
            let other = pattern(5, 2 * Self.block)
            guard let bad  = makeFile(&fs, "bad.bin", pattern(4, 2 * Self.block)),
                  let good = makeFile(&fs, "good.bin", other)
            else { return }

            rot(disk, physical(&fs, bad, 1), at: 0)
            #expect(readBack(&fs, bad, count: 2 * Self.block).status == .damaged)

            #expect(readBack(&fs, good, count: other.count).data == other)
            #expect(writeBytes(&fs, good, at: UInt64(other.count), pattern(6, 100)).status == .ok)
            #expect(makeFile(&fs, "new.bin", pattern(7, 300)) != nil)

            let findings = fs.scan(.everything)
            #expect(findings.safeToServe)
            #expect(!fs.corrupted)

            // And a volume with a damaged file is still one a shutdown seals: the
            // seal is about the metadata, which is whole.
            #expect(fs.unmount() == .ok)
            #expect(fs.namedSeal != 0)
        }
    }


    @Test("a whole-block write puts a damaged block right, and a partial one is refused")
    func wholeBlockHeals() {
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "heal.bin", pattern(8, 2 * Self.block)) else { return }

            let home = physical(&fs, file, 1)
            rot(disk, home, at: 9)
            let damaged = disk.block(home)
            let writes  = disk.writes

            // Keeping part of a block means reading it, and it cannot be read.
            let partial = writeBytes(&fs, file, at: UInt64(Self.block + 10), pattern(9, 5))
            #expect(partial.status == .damaged)
            #expect(partial.bytes == 0)
            #expect(disk.writes == writes)
            #expect(disk.block(home) == damaged)
            #expect(fs.journalIsEmpty && fs.unsettled.isEmpty)

            // Replacing all of it needs nothing from it.
            let fresh = pattern(10, Self.block)
            #expect(writeBytes(&fs, file, at: UInt64(Self.block), fresh).status == .ok)

            let back = readBack(&fs, file, at: UInt64(Self.block), count: Self.block)
            #expect(back.status == .ok)
            #expect(back.data == fresh)
        }
    }


    @Test("an overwrite ending inside a damaged block is refused before anything is written")
    func damagedTailIsReadFirst() {
        withFileSystem { fs, disk in
            let content = pattern(11, 3 * Self.block)
            guard let file = makeFile(&fs, "tail.bin", content) else { return }

            rot(disk, physical(&fs, file, 2), at: 500)

            let first  = disk.block(physical(&fs, file, 0))
            let writes = disk.writes

            // From inside the first block to inside the third: the third is read
            // before the first is named or touched.
            let done = writeBytes(&fs, file, at: 100, pattern(12, 2 * Self.block))
            #expect(done.status == .damaged)
            #expect(disk.writes == writes)
            #expect(disk.block(physical(&fs, file, 0)) == first)
            #expect(fs.journalIsEmpty && fs.unsettled.isEmpty)
            #expect(fs.object(file)?.size == UInt64(content.count))
        }
    }


    @Test("an append onto a damaged last block is refused, and the file keeps its size")
    func damagedLastBlockStopsAnAppend() {
        withFileSystem { fs, disk in
            let content = pattern(13, Self.block + 100)
            guard let file = makeFile(&fs, "log.bin", content) else { return }

            rot(disk, physical(&fs, file, 1), at: 50)

            let done = writeBytes(&fs, file, at: UInt64(content.count), pattern(14, 10))
            #expect(done.status == .damaged)
            #expect(fs.object(file)?.size == UInt64(content.count))
        }
    }


    @Test("putting a file back together checks what it copies, and carries the checksums along")
    func compactionChecksAndCarries() {
        withFileSystem { fs, disk in
            guard let middle = fragmented(&fs) else { return }
            let content = readBack(&fs, middle, count: 3 * Self.block).data

            #expect(fs.compact(middle) == .ok)
            #expect(fs.object(middle)?.extents == 1)

            fs.dropCache()
            let back = readBack(&fs, middle, count: 3 * Self.block)
            #expect(back.status == .ok)
            #expect(back.data == content)
            #expect(fs.scan(.data).damagedData == 0)
        }

        withFileSystem { fs, disk in
            guard let middle = fragmented(&fs) else { return }

            rot(disk, physical(&fs, middle, 2), at: 1)

            #expect(fs.compact(middle) == .damaged)
            #expect(fs.object(middle)?.extents == 2)
            #expect(readBack(&fs, middle, count: 2 * Self.block).status == .ok)
        }
    }


    // MARK: - Who looks

    @Test("only a data scrub reads the data, and it counts what is damaged")
    func dataScrubCounts() {
        withFileSystem { fs, disk in
            guard let a = makeFile(&fs, "a.bin", pattern(15, 5 * Self.block)),
                  let b = makeFile(&fs, "b.bin", pattern(16, 3 * Self.block))
            else { return }

            rot(disk, physical(&fs, a, 4), at: 4095)
            rot(disk, physical(&fs, b, 0), at: 0)

            fs.dropCache()
            var before = disk.reads
            let shallow = fs.scan(.everything)
            let shallowReads = disk.reads - before

            #expect(shallow.complete && shallow.safeToServe)
            #expect(shallow.damagedData == 0)

            fs.dropCache()
            before = disk.reads
            let deep = fs.scan(.data)

            #expect(deep.complete && deep.safeToServe)
            #expect(deep.depth == .data)
            #expect(deep.damagedData == 2)

            // Every block of both files, on top of everything the other scan read.
            #expect(disk.reads - before >= shallowReads + 8)
            #expect(!fs.corrupted)
        }
    }


    @Test("a sum block changed while the disk was shut down is caught at its first read")
    func sealCoversTheSums() {
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "sealed.bin", pattern(17, Self.block)) else { return }
            let home = physical(&fs, file, 0)
            let sums = fs.sumBlock(of: home)
            let at   = Int(sums) * Self.block + fs.sumOffset(of: home)

            #expect(fs.unmount() == .ok)
            #expect(fs.namedSeal != 0)

            // Untouched, the seal hands the sum block's checksum over and the read
            // agrees with it.
            remount(disk) { again, found in
                guard var again else { Issue.record("\(found)"); return }

                #expect(readBack(&again, file, count: 10).status == .ok)
                #expect(again.unmount() == .ok)
                #expect(again.namedSeal != 0)
            }

            disk.poke(disk.byte(at: at) ^ 0x01, at: at)

            remount(disk) { again, found in
                guard var again else { Issue.record("\(found)"); return }

                // The seal is believed without the sum region being read.
                #expect(!again.wasDirty)
                #expect(readBack(&again, file, count: 10).status == .quarantined)
                #expect(again.corrupted)
            }
        }
    }


    @Test("a dirty mount learns the sums from the disk and still refuses a damaged block")
    func dirtyMountLearns() {
        withFileSystem { fs, disk in
            let content = pattern(18, 2 * Self.block)
            guard let file = makeFile(&fs, "dirty.bin", content) else { return }

            rot(disk, physical(&fs, file, 1), at: 3)

            remount(disk) { again, found in
                guard var again else { Issue.record("\(found)"); return }

                #expect(again.wasDirty)
                #expect(readBack(&again, file, count: Self.block).data == Array(content[0..<Self.block]))
                #expect(readBack(&again, file, at: UInt64(Self.block), count: 1).status == .damaged)
                #expect(again.scan(.data).damagedData == 1)
            }
        }
    }


    // MARK: - The overwrite limit

    @Test("an overwrite past the limit is refused before anything is spent, and one at it is not")
    func overwriteLimit() {
        withFileSystem { fs, disk in
            let limit = Int(FSLayout.overwriteLimit)
            guard let file = makeFile(&fs, "wide.bin", pattern(19, (limit + 1) * Self.block)) else {
                return
            }

            let writes = disk.writes
            let over   = writeBytes(&fs, file, at: 0, pattern(20, (limit + 1) * Self.block))
            #expect(over.status == .tooManyChanges)
            #expect(disk.writes == writes)

            // Starting one block in, the same length lands on `limit` blocks the
            // file has and one it does not.
            let at = writeBytes(&fs, file, at: UInt64(Self.block), pattern(21, (limit + 1) * Self.block))
            #expect(at.status == .ok)
        }
    }


    // MARK: - What a named overwrite leaves for the mount

    @Test("a prepared header naming an overwrite is settled from the medium, and only what it names")
    func preparedIntentIsSettled() {
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "named.bin", pattern(22, 2 * Self.block)) else { return }

            let named   = physical(&fs, file, 0)
            let unnamed = physical(&fs, file, 1)
            let landed  = pattern(23, Self.block)

            // Both overwrites reached the medium and neither commit did. Only the
            // first was named before it was written.
            disk.put(landed, block: named)
            disk.put(pattern(24, Self.block), block: unnamed)

            var intent = FSJournal.Intent()
            let added  = intent.add(named)
            #expect(added)
            putHeader(disk, prepared: intent)

            remount(disk) { again, found in
                guard var again else { Issue.record("\(found)"); return }

                let first = readBack(&again, file, count: Self.block)
                #expect(first.status == .ok)
                #expect(first.data == landed)

                #expect(readBack(&again, file, at: UInt64(Self.block), count: 1).status == .damaged)
                #expect(again.journalIsEmpty && again.unsettled.isEmpty)
            }
        }
    }


    @Test("a header whose intent is not file data on this disk holds the volume still")
    func impossibleIntentIsRefused() {
        let cases: [(String, (inout FSJournal, FSLayout.Plan) -> Void)] = [
            ("the front of the disk", { header, plan in
                header.intent.runs[0] = FSExtent(start: plan.tableStart, count: 1)
                header.intent.count   = 1
            }),
            ("past the end", { header, plan in
                header.intent.runs[0] = FSExtent(start: plan.totalBlocks - 1, count: 2)
                header.intent.count   = 1
            }),
            ("an empty run", { header, plan in
                header.intent.runs[0] = FSExtent(start: plan.dataStart, count: 0)
                header.intent.count   = 1
            }),
            ("past the overwrite limit", { header, plan in
                header.intent.runs[0] = FSExtent(
                    start: plan.dataStart, count: UInt32(FSLayout.overwriteLimit) + 1
                )
                header.intent.count = 1
            }),
        ]

        for (label, edit) in cases {
            withFileSystem { fs, disk in
                var header = FSJournal()
                header.state = .prepared
                edit(&header, fs.plan)
                putHeader(disk, header)

                let writes = disk.writes
                remount(disk) { again, found in
                    #expect(again == nil, "\(label)")
                    #expect(isCorrupt(found), "\(label): \(found)")
                }
                #expect(disk.writes == writes, "\(label)")
            }
        }

        // And a count past eight is not a header at all, whatever it checksums to,
        // even when the eight it can hold are all file data.
        withFileSystem { fs, disk in
            var header = FSJournal()
            header.state = .prepared

            for run in 0..<FSJournal.Intent.limit {
                header.intent.runs[run] = FSExtent(start: fs.plan.dataStart + UInt32(2 * run), count: 1)
            }
            header.intent.count = FSJournal.Intent.limit

            var bytes = [UInt8](repeating: 0, count: Self.block)
            bytes.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                header.write(to: base)
                base.storeBytes(of: UInt32(9), toByteOffset: FSJournal.Header.intentCount, as: UInt32.self)
                base.storeBytes(
                    of: FSChecksum.over(base, count: FSJournal.Header.width, zeroing: FSJournal.Header.checksum),
                    toByteOffset: FSJournal.Header.checksum, as: UInt32.self
                )
            }
            disk.put(bytes, block: FSLayout.journalHeaderBlock)

            remount(disk) { again, found in
                #expect(again == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("an overwrite the device refused part way leaves every block readable once it answers")
    func refusedOverwriteIsSettled() {
        let old = pattern(25, 4 * Self.block)
        let new = pattern(26, 3 * Self.block)

        var refused = 0
        var landed  = 0

        for stop in 1...24 {
            withFileSystem { fs, disk in
                guard let file = makeFile(&fs, "over.bin", old) else { return }

                disk.failAfter(stop)
                let done = writeBytes(&fs, file, at: 100, new)
                disk.recover()

                if done.status == .ok { landed += 1 } else { refused += 1 }

                // The next change settles whatever the refusal left named. A
                // committed journal is a promise only a mount finishes.
                if fs.journalState != .committed {
                    #expect(fs.begin() == .ok, "stop \(stop)")
                    fs.abort()
                    #expect(fs.unsettled.isEmpty, "stop \(stop)")
                    check(&fs, file, old: old, new: new, at: 100, "stop \(stop), live")
                }

                remount(disk) { again, found in
                    guard var again else { Issue.record("stop \(stop): \(found)"); return }
                    check(&again, file, old: old, new: new, at: 100, "stop \(stop), remounted")
                }
            }
        }

        #expect(refused > 0 && landed > 0)
    }


    /// Every byte of `file` is what it was or what the write said, every block
    /// reads, and a data scrub finds nothing.
    private func check(
        _ fs  : inout FileSystem<MemoryDisk>,
        _ file: UInt32,
        old   : [UInt8],
        new   : [UInt8],
        at    : Int,
        _ what: String
    ) {
        let back = readBack(&fs, file, count: old.count)
        #expect(back.status == .ok, "\(what): \(back.status)")

        for index in 0..<old.count {
            let fresh = index >= at && index < at + new.count ? new[index - at] : old[index]
            guard back.data[index] == old[index] || back.data[index] == fresh else {
                Issue.record("\(what): byte \(index) is neither")
                break
            }
        }

        #expect(fs.scan(.data).damagedData == 0, "\(what)")
    }


    @Test("an overwrite that lost one request is settled before the write returns")
    func oneRefusalIsSettledAtOnce() {
        let old = pattern(35, 4 * Self.block)
        let new = pattern(36, 3 * Self.block)

        // Every request the write makes, and no request after it.
        var requests = 0
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "once.bin", old) else { return }
            let before = disk.reads + disk.writes + disk.flushes
            #expect(writeBytes(&fs, file, at: 100, new).status == .ok)
            requests = disk.reads + disk.writes + disk.flushes - before
        }

        var settled = 0

        for stop in 1...requests {
            withFileSystem { fs, disk in
                guard let file = makeFile(&fs, "once.bin", old) else { return }

                disk.refuseOnly(stop)
                let done = writeBytes(&fs, file, at: 100, new)

                // Named but not promised: the abandoning write settles it. Promised:
                // the next mount finishes it, the home sum lagging until then.
                if fs.journalState != .committed {
                    #expect(fs.unsettled.isEmpty, "stop \(stop)")
                    #expect(fs.journalIsEmpty, "stop \(stop)")
                    if done.status != .ok { settled += 1 }

                    check(&fs, file, old: old, new: new, at: 100, "stop \(stop), live")
                }

                remount(disk) { again, found in
                    guard var again else { Issue.record("stop \(stop): \(found)"); return }
                    check(&again, file, old: old, new: new, at: 100, "stop \(stop), remounted")
                }
            }
        }

        #expect(settled > 0)
    }


    // MARK: - The format

    @Test("the sum region sits between the table and the data, one checksum per block")
    func geometry() {
        guard let small = FSLayout.Plan(sectorCount: 32768, sectorSize: 512),
              let large = FSLayout.Plan(sectorCount: 2097152, sectorSize: 512)
        else { Issue.record("no plan"); return }

        #expect(small.sumStart == small.tableStart + small.tableBlocks)
        #expect(small.sumBlocks == 4)
        #expect(small.sealBlocks == 3)
        #expect(small.dataStart == 59)

        #expect(large.sumBlocks == 256)
        #expect(large.sealBlocks == 5)
        #expect(large.dataStart == 2336)
        #expect(UInt64(large.sumBlocks) * FSLayout.sumsPerBlock >= UInt64(large.totalBlocks))
    }


    @Test("a disk laid down before the sum region is refused as unrecognised, untouched")
    func diskBeforeTheSumsIsRefused() {
        withFileSystem { fs, disk in
            let plan = fs.plan

            // This build's superblock with the data where the sums now are: what
            // a disk made before them says, byte for byte apart from the name.
            for copy in [FSLayout.superblockA, FSLayout.superblockB] {
                var bytes = disk.block(copy)
                bytes.withUnsafeMutableBytes { raw in
                    var old = FSSuperblock(reading: raw.baseAddress!)
                    old.dataStart = plan.sumStart
                    old.write(to: raw.baseAddress!)
                }
                disk.put(bytes, block: copy)
            }

            let before = (disk.block(FSLayout.superblockA), disk.block(FSLayout.superblockB))
            let writes = disk.writes

            remount(disk) { again, found in
                #expect(again == nil)
                #expect(isUnrecognised(found), "\(found)")
            }

            #expect(disk.writes == writes)
            #expect(disk.block(FSLayout.superblockA) == before.0)
            #expect(disk.block(FSLayout.superblockB) == before.1)
        }
    }


    // MARK: - What it costs

    @Test("an overwrite in place pays one header and one barrier more, an append none")
    func costOfNaming() {
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "bill.bin", pattern(27, 100)) else { return }

            // Onto the block the file has: named first.
            var writes  = disk.writes
            var flushes = disk.flushes
            var reads   = disk.reads
            #expect(writeBytes(&fs, file, at: 100, pattern(28, 100)).status == .ok)

            let inPlace = (disk.writes - writes, disk.flushes - flushes, disk.reads - reads)

            // Data block, declaration, two payloads, three headers, two home
            // writes; five barriers; one read, of the block being kept.
            #expect(inPlace.0 == 9, "\(inPlace)")
            #expect(inPlace.1 == 5, "\(inPlace)")
            #expect(inPlace.2 == 1, "\(inPlace)")

            // Onto a block it does not have: nothing to name.
            guard let other = makeFile(&fs, "fresh.bin", []) else { return }
            writes  = disk.writes
            flushes = disk.flushes
            #expect(writeBytes(&fs, other, at: 0, pattern(29, 100)).status == .ok)

            // The data block, three payloads (the bitmap too), three headers and
            // three home writes; four barriers.
            #expect(disk.writes - writes == 10)
            #expect(disk.flushes - flushes == 4)
        }
    }


    @Test("reading a file asks for its sum block once per four megabytes")
    func costOfChecking() {
        withFileSystem { fs, disk in
            guard let file = makeFile(&fs, "read.bin", pattern(30, 16 * Self.block)) else { return }

            fs.dropCache()
            let reads = disk.reads
            #expect(readBack(&fs, file, count: 16 * Self.block).status == .ok)

            // Sixteen blocks, the sum block that covers all of them, and the
            // table block the record is in.
            #expect(disk.reads - reads == 18)
        }
    }


    // MARK: - Helpers

    /// Bytes that differ from block to block and from seed to seed.
    private func pattern(_ seed: UInt8, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 101 &+ $0 / 4096) }
    }

    private func makeFile(
        _ fs     : inout FileSystem<MemoryDisk>,
        _ name   : StaticString,
        _ content: [UInt8]
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
            kind: .file, in: FSLayout.rootObject
        )
        guard made.status == .ok else { Issue.record("create \(name): \(made.status)"); return nil }
        guard !content.isEmpty else { return made.object }

        let done = writeBytes(&fs, made.object, at: 0, content)
        guard done.status == .ok else { Issue.record("write \(name): \(done.status)"); return nil }

        return made.object
    }

    private func writeBytes(
        _ fs     : inout FileSystem<MemoryDisk>,
        _ file   : UInt32,
        at offset: UInt64,
        _ bytes  : [UInt8]
    ) -> (status: FSStatus, bytes: UInt64) {
        bytes.withUnsafeBytes { raw in
            fs.write(file, at: offset, from: raw.baseAddress!, count: UInt64(bytes.count))
        }
    }

    private func readBack(
        _ fs     : inout FileSystem<MemoryDisk>,
        _ file   : UInt32,
        at offset: UInt64 = 0,
        count    : Int
    ) -> (status: FSStatus, bytes: UInt64, data: [UInt8]) {
        var data = [UInt8](repeating: 0, count: count)
        let done = data.withUnsafeMutableBytes { raw in
            fs.read(file, at: offset, into: raw.baseAddress!, count: UInt64(count))
        }
        return (done.status, done.bytes, data)
    }

    /// Where block `index` of `file` is on the disk.
    private func physical(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32, _ index: Int) -> UInt32 {
        fs.object(file)?.block(at: UInt64(index * Self.block)) ?? 0
    }

    /// One byte of a block, changed behind everybody's back.
    private func rot(_ disk: MemoryDisk, _ block: UInt32, at offset: Int) {
        let at = Int(block) * Self.block + offset
        disk.poke(disk.byte(at: at) ^ 0xA5, at: at)
    }

    /// A three-block file in two extents, between two one-block files.
    private func fragmented(_ fs: inout FileSystem<MemoryDisk>) -> UInt32? {
        guard makeFile(&fs, "a.bin", pattern(31, Self.block)) != nil,
              let middle = makeFile(&fs, "b.bin", pattern(32, Self.block)),
              makeFile(&fs, "c.bin", pattern(33, Self.block)) != nil,
              writeBytes(&fs, middle, at: UInt64(Self.block), pattern(34, 2 * Self.block)).status == .ok
        else { return nil }

        #expect(fs.object(middle)?.extents == 2)
        return middle
    }

    private func putHeader(_ disk: MemoryDisk, prepared intent: FSJournal.Intent) {
        var header = FSJournal()
        header.state  = .prepared
        header.intent = intent
        putHeader(disk, header)
    }

    private func putHeader(_ disk: MemoryDisk, _ header: FSJournal) {
        var bytes = [UInt8](repeating: 0, count: Self.block)
        bytes.withUnsafeMutableBytes { raw in header.write(to: raw.baseAddress!) }
        disk.put(bytes, block: FSLayout.journalHeaderBlock)
    }
}


/// Power cuts at every request of every write path that moves a checksum.
///
/// `CrashDisk` keeps what it has only accepted in a queue that a cut throws away,
/// or lands in part, in an order the cut chooses. So each stop is a device that
/// refuses from its nth request onward and then loses power, kept five ways:
/// nothing of the queue, all of it, its newest write, its oldest, and all of it
/// shuffled. Whatever lands, the next mount must serve every byte of the file as
/// either what it was or what the write said, and a data scrub must find nothing.
@Suite("An overwrite survives the power", .serialized)
struct DataSumCrashTests {

    /// 2 MiB: small enough to mount several hundred times.
    private static let sectors: UInt64 = 4096

    private static let block = Int(FSLayout.blockSize)

    private static let policies: [(String, (Int) -> CrashDisk.Survivors)] = [
        ("nothing", { _ in .nothing }),
        ("everything", { _ in .everything }),
        ("the newest", { _ in .reversePrefix(1) }),
        ("the oldest", { _ in .single(0) }),
        ("shuffled", { stop in .permuted(UInt64(stop)) }),
    ]


    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<CrashDisk>.scratchBytes, alignment: 8
        )
    }


    /// Sweeps `operation` over a file holding `old` that should come to hold
    /// `new`, at every stop and under every policy.
    private func sweep(
        _ what     : String,
        old        : [UInt8],
        new        : [UInt8],
        initial    : [UInt8]? = nil,
        prepare    : (inout FileSystem<CrashDisk>, UInt32) -> Void = { _, _ in },
        operation  : (inout FileSystem<CrashDisk>, UInt32) -> Void
    ) {
        // How many requests the operation makes when nothing goes wrong, so the
        // sweep covers every one of them and one past the end.
        var requests = 0
        fixture(initial ?? old, prepare) { fs, disk, file in
            let before = disk.reads + disk.writes + disk.flushes
            operation(&fs, file)
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 0, "\(what): the operation asked nothing of the disk")

        var finished = 0
        var undone   = 0

        for stop in 1...(requests + 1) {
            for (label, policy) in Self.policies {
                fixture(initial ?? old, prepare) { fs, disk, file in
                    disk.failAfter(stop)
                    operation(&fs, file)
                    disk.powerCut(keeping: policy(stop))

                    let after = CrashDisk(restarting: disk)
                    let space = scratch()
                    defer { space.deallocate() }

                    let where_ = "\(what) stop \(stop), \(label)"
                    let attempt = FileSystem.mount(after, scratch: space)

                    guard var again = attempt.disk else {
                        Issue.record("\(where_): would not mount, \(attempt.found)")
                        return
                    }

                    #expect(again.begin() == .ok, "\(where_): the journal was left holding something")
                    again.abort()

                    let findings = again.scan(.data)
                    #expect(findings.complete && findings.safeToServe, "\(where_)")
                    #expect(findings.damagedData == 0, "\(where_): a block reads as damaged")

                    guard let record = again.object(file) else {
                        Issue.record("\(where_): the file is gone")
                        return
                    }

                    let size = Int(record.size)
                    #expect(size == old.count || size == new.count, "\(where_): size \(size)")

                    var back = [UInt8](repeating: 0, count: size)
                    let read = back.withUnsafeMutableBytes { raw in
                        again.read(file, at: 0, into: raw.baseAddress!, count: UInt64(size))
                    }
                    #expect(read.status == .ok, "\(where_): \(read.status)")

                    for index in 0..<size {
                        let was  = index < old.count ? old[index] : nil
                        let will = index < new.count ? new[index] : nil
                        guard back[index] == was || back[index] == will else {
                            Issue.record("\(where_): byte \(index) is neither")
                            break
                        }
                    }

                    if back == new { finished += 1 } else if back == old { undone += 1 }
                }
            }
        }

        // Both outcomes have to happen, or the sweep asserted something about
        // runs that never reached the write. Moot when the bytes do not change.
        guard old != new else { return }

        #expect(finished > 0, "\(what): no stop finished the write")
        #expect(undone   > 0, "\(what): no stop left it undone")
    }


    /// A formatted disk holding one file of `old`, made durable, then `body`.
    private func fixture(
        _ old    : [UInt8],
        _ prepare: (inout FileSystem<CrashDisk>, UInt32) -> Void,
        _ body   : (inout FileSystem<CrashDisk>, CrashDisk, UInt32) -> Void
    ) {
        let disk  = CrashDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        let name: StaticString = "file.bin"
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
            kind: .file, in: FSLayout.rootObject
        )
        guard made.status == .ok else { Issue.record("create"); return }

        let wrote = old.withUnsafeBytes { raw in
            fs.write(made.object, at: 0, from: raw.baseAddress!, count: UInt64(old.count))
        }
        guard wrote.status == .ok else { Issue.record("fixture write"); return }

        prepare(&fs, made.object)
        #expect(disk.flush() == .ok)

        body(&fs, disk, made.object)
    }


    private func pattern(_ seed: UInt8, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed) &* 59 &+ $0 / 512) }
    }

    private func write(
        _ fs     : inout FileSystem<CrashDisk>,
        _ file   : UInt32,
        at offset: Int,
        _ bytes  : [UInt8],
        replacing: Bool = false
    ) {
        _ = bytes.withUnsafeBytes { raw in
            fs.write(
                file, at: UInt64(offset), from: raw.baseAddress!,
                count: UInt64(bytes.count), replacing: replacing
            )
        }
    }


    @Test("an append onto a block the file has")
    func appendInPlace() {
        let old   = pattern(1, Self.block + 50)
        let extra = pattern(2, 100)

        sweep("append in place", old: old, new: old + extra) { fs, file in
            write(&fs, file, at: old.count, extra)
        }
    }


    @Test("an append that fills the last block and carries on into a new one")
    func appendAcross() {
        let old   = pattern(3, Self.block + 50)
        let extra = pattern(4, 5000)

        sweep("append across", old: old, new: old + extra) { fs, file in
            write(&fs, file, at: old.count, extra)
        }
    }


    @Test("an overwrite inside a file, partial at both ends")
    func overwriteInside() {
        let old  = pattern(5, 3 * Self.block)
        let over = pattern(6, 2 * Self.block)
        var new  = old
        new.replaceSubrange(1000..<(1000 + over.count), with: over)

        sweep("overwrite inside", old: old, new: new) { fs, file in
            write(&fs, file, at: 1000, over)
        }
    }


    @Test("an overwrite of whole blocks")
    func overwriteWhole() {
        let old  = pattern(7, 3 * Self.block)
        let over = pattern(8, 2 * Self.block)
        var new  = old
        new.replaceSubrange(Self.block..<(3 * Self.block), with: over)

        sweep("overwrite whole", old: old, new: new) { fs, file in
            write(&fs, file, at: Self.block, over)
        }
    }


    @Test("a replacement that shortens the file")
    func replaceShorter() {
        let old  = pattern(9, 3 * Self.block)
        let over = pattern(10, 300)
        let new  = over

        sweep("replace", old: old, new: new) { fs, file in
            write(&fs, file, at: 0, over, replacing: true)
        }
    }


    @Test("putting a file back together")
    func compaction() {
        let old  = pattern(11, Self.block)
        let more = pattern(12, 2 * Self.block)

        // Grown after a neighbour took the blocks it would have grown into, so
        // it is in two runs and the sweep's operation has something to move.
        let prepare: (inout FileSystem<CrashDisk>, UInt32) -> Void = { fs, file in
            let name: StaticString = "next.bin"
            let next = fs.create(
                UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                kind: .file, in: FSLayout.rootObject
            )
            let one = [UInt8](repeating: 0x42, count: Self.block)
            _ = one.withUnsafeBytes { raw in
                fs.write(next.object, at: 0, from: raw.baseAddress!, count: UInt64(one.count))
            }
            write(&fs, file, at: Self.block, more)
            #expect(fs.object(file)?.extents == 2)
        }

        // The bytes do not change, so the sweep cannot tell finished from
        // undone by them. The run that counts the requests can, by the extents.
        var moved = false
        sweep(
            "compact", old: old + more, new: old + more, initial: old, prepare: prepare
        ) { fs, file in
            _ = fs.compact(file)
            if fs.object(file)?.extents == 1 { moved = true }
        }
        #expect(moved)
    }
}
