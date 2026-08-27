//
//  CostTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Testing
@testable import ReixFS
import ReixABI

/// What operations cost in round trips to the disk.
///
/// `MemoryDisk` counts its own traffic, so these are exact numbers and not
/// estimates. They are here because a report about performance is worth nothing
/// without them: the one thing that turned out to be badly wrong was found by
/// measuring, and three things that looked wrong turned out to be cheap enough
/// to leave alone.
///
/// Written as ceilings with the measured figure named, the same discipline the
/// kernel stack watermark uses. A ceiling fails when something gets worse and
/// does not have to be edited every time something gets better - and the numbers
/// in the comments say what "better" would look like.
///
/// The write path is the expensive one and is *meant* to be. Most of what it
/// spends goes on the ordering rule: the block map reaches the disk before any
/// record points at the blocks, and a barrier separates the two. That is not
/// overhead to be optimised away, it is the reason a power cut does not lose a
/// file, so the number here is a record of what durability costs rather than a
/// target to beat.
@Suite("Disk traffic", .serialized)
struct CostTests {

    private static let sectors: UInt64 = 32768   // 16 MiB, the Makefile's image

    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
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

    @discardableResult
    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString
    ) -> UInt32? {
        fs.create(
            UnsafeRawPointer(text.utf8Start),
            length: text.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        ).object
    }


    /// The one that was wrong. Asking whether a run of blocks is free used to go
    /// through `isUsed` a block at a time, and `isUsed` loads a bitmap block per
    /// call: a run of thirty-two cost **thirty-three reads** of the same block,
    /// against the one its own comment claimed.
    ///
    /// Two once the loop was fixed: one to check, one that `setRange` makes to
    /// modify. One now, because the bitmap block stays in hand across the two
    /// calls - and zero for every run after the first, which is what the cache
    /// is here for. The cache does not excuse the loop: turning thirty-two round
    /// trips into thirty-two lookups is not the same as not making them.
    @Test("claiming a run of blocks reads the bitmap once, not once per block")
    func allocateAtReadsOneBitmapBlock() {
        withFileSystem { fs, disk in

            // Inside a transaction, because claiming a block is a change to the
            // disk's own bookkeeping and there is no longer a path from one of
            // those to the medium that does not go through a journal.
            #expect(fs.begin() == .ok)
            defer { fs.abort() }

            for count in [UInt32(1), 8, 32, 256] {
                let reads  = disk.reads
                let writes = disk.writes

                let claimed = fs.allocateAt(fs.plan.dataStart + 2000 + count * 4, count: count)
                #expect(claimed == .ok, "count \(count)")

                // Was 33 for count 32, then 2, and 1 now.
                #expect(disk.reads  - reads  <= 1, "count \(count)")
                #expect(disk.writes - writes <= 1, "count \(count)")
            }
        }
    }


    /// A run that straddles two bitmap blocks reads both, and the point is that
    /// it reads them twice over rather than once per block.
    @Test("a run across a bitmap boundary reads both blocks and no more")
    func allocateAtAcrossABoundary() {
        withFileSystem { fs, disk in

            let perBlock = UInt32(FileSystem<MemoryDisk>.blocksPerBitmapBlock)

            // Nothing to straddle on a disk with one bitmap block, which is what
            // sixteen megabytes gives: recorded rather than skipped silently.
            guard perBlock < fs.plan.totalBlocks else {
                #expect(fs.plan.totalBlocks <= perBlock)
                return
            }

            let reads   = disk.reads
            let claimed = fs.allocateAt(perBlock - 4, count: 8)
            #expect(claimed == .ok)
            #expect(disk.reads - reads <= 4)
        }
    }


    /// Listing. Every step re-reads the folder's own record and the directory
    /// block the name sits in, and the first of those two is now free: the
    /// folder's record is one of the file system's own blocks and stays in hand.
    /// Twenty-four reads for eleven names, then eleven, then two.
    ///
    /// The middle number was one read of the directory block per name, and the
    /// note here said taking it would be "a wire change for a saving nobody can
    /// feel on a disk this size". That was wrong twice over: the wire change is
    /// four words, and the saving is not the reads - it is the round trips, one
    /// per name, each of which parks the caller.
    @Test("listing a folder costs one pass, not one read per name")
    func listingCostsOnePass() {
        withFileSystem { fs, disk in

            let names: [StaticString] = ["a0","a1","a2","a3","a4","a5","a6","a7","a8","a9"]
            for name in names { make(&fs, name) }

            let room = UnsafeMutableRawPointer.allocate(
                byteCount: 32 * FSListEntry.width, alignment: 8
            )
            defer { room.deallocate() }

            let reads = disk.reads

            let batch = fs.entries(
                from: 0, in: FSLayout.rootObject, into: room, capacity: 32
            )

            #expect(batch.count == names.count)
            #expect(batch.eof)

            // Measured at two: the one directory block, and the one table block
            // the ten records share. Was 11 for the same ten names, and 22
            // before the cache.
            #expect(disk.reads - reads <= 2)
        }
    }


    /// Reading is at the floor now: one read per block of data and nothing else.
    /// The record was the other half of the bill - one per call, sixteen for
    /// sixteen calls - and a record is one of the file system's own blocks.
    @Test("reading a file costs its blocks and nothing else")
    func readingIsNearTheFloor() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "big.bin") else { return }

            let page = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { page.deallocate() }
            page.initializeMemory(as: UInt8.self, repeating: 0xAB, count: 4096)

            for step in 0..<16 {
                _ = fs.write(file, at: UInt64(step) * 4096, from: page, count: 4096)
            }

            let reads  = disk.reads
            let writes = disk.writes

            for step in 0..<16 {
                _ = fs.read(file, at: UInt64(step) * 4096, into: page, count: 4096)
            }

            // Was 32, one record and one data block per call. Measured at 16.
            #expect(disk.reads - reads <= 18)

            // And nothing written. A read that writes is a read with a bug.
            #expect(disk.writes == writes)
        }
    }


    /// What durability costs, recorded rather than trimmed.
    ///
    /// Sixteen calls of four kilobytes each. The history of this number is the
    /// history of the format:
    ///
    /// - 144 reads and 80 writes, before the metadata cache;
    /// - 0 reads and 80 writes, with it;
    /// - 0 reads and 160 writes, with the journal.
    ///
    /// The reads stayed gone, which took work: staging puts the after-image in
    /// the cache under the target's own number, and finishing a commit takes the
    /// image from there rather than reading back the payload it just wrote.
    /// Without either of those this is 80 reads.
    ///
    /// The writes doubled and the reason is the whole point of the journal. Each
    /// append is one transaction of ten writes: one of file data, five journal
    /// payload writes, three headers, and two home blocks. The two home blocks
    /// are the bitmap and the object table, which is what it always was; the
    /// other eight are what buys the property that the eighty writes never had -
    /// that a power cut anywhere in the sixteen leaves a file of some whole
    /// number of blocks and never a size pointing at a block the map calls free.
    ///
    /// Five payload writes for two distinct blocks, because the object table is
    /// staged three times in one call - the container's room, the extent map, the
    /// size - and each staging rewrites its payload. They share one slot and one
    /// home write, which is the coalescing that matters; writing the payload once
    /// as well would need the whole transaction's images held in memory, which is
    /// sixteen blocks of scratch this server does not have. The way out is fewer
    /// and larger writes from the client, and that is a measurement for later.
    @Test("writing pays for the ordering rule, and the bill is this")
    func writingPaysForOrdering() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "big.bin") else { return }

            let page = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { page.deallocate() }
            page.initializeMemory(as: UInt8.self, repeating: 0xCD, count: 4096)

            let reads  = disk.reads
            let writes = disk.writes

            for step in 0..<16 {
                let done = fs.write(file, at: UInt64(step) * 4096, from: page, count: 4096)
                #expect(done.status == .ok)
            }

            // Measured, not chosen. The reads are the number to defend: the
            // write path still asks the disk for nothing it did not itself put
            // there, journal or no journal.
            #expect(disk.reads  - reads  <= 2)

            // Was a hundred and sixty. Each of the sixteen appends staged the
            // bitmap block and the table block, and staging used to write a
            // payload per call; now the arena holds the image and the commit
            // writes each one once, so two of the ten writes per append are gone.
            #expect(disk.writes - writes == 128)
        }
    }

    /// The direction the cheaper loop must not get wrong.
    ///
    /// `isUsed` answered "taken" for a bitmap block it could not read, and the
    /// run check that replaced it has to answer "not free" for the same reason:
    /// a disk that will not say whether a block is spoken for must never have
    /// that block handed out, or two files end up owning it.
    ///
    /// Checked on `allFree` itself and not only through `allocateAt`, because
    /// `setRange` refuses on the same failure a moment later and would cover for
    /// it. The scratch is primed with a bitmap block that really is free first,
    /// so a version of this that ignored the read failure would find "free" left
    /// over in the buffer and say yes.
    ///
    /// Not a performance property, and here because it is the same function. It
    /// went untested for as long as the slow loop existed.
    @Test("a bitmap block that cannot be read means the blocks are not free")
    func unreadableBitmapRefuses() {
        withFileSystem { fs, disk in

            let start = fs.plan.dataStart + 4000

            let free = fs.allFree(start: start, count: 8)
            #expect(free)

            // That first call put the bitmap block in hand, and a block in hand
            // is not one the device gets asked for. Without this the refusal
            // below never reaches `allFree`, and the guard goes untested.
            fs.dropCache()

            disk.failAfter(0)

            let unknown = fs.allFree(start: start, count: 8)
            #expect(!unknown)

            #expect(fs.begin() == .ok)

            let refused = fs.allocateAt(start, count: 8)

            // The disk stopping and the blocks being somebody else's are not the
            // same answer any more, and this is the one that used to be lost.
            #expect(refused == .deviceFailed)

            // And nothing was claimed on the way out: the same run is still
            // there to be had once the disk answers again.
            disk.recover()
            let claimed = fs.allocateAt(start, count: 8)
            #expect(claimed == .ok)

            fs.abort()
        }
    }


    // MARK: - What is held in hand

    /// That the cache is *used*, and not merely there.
    ///
    /// Every number above would look the same if it were dead code: a cache that
    /// is never hit and a cache that does not exist give identical answers, and
    /// this session has already been caught twice by exactly that shape - a
    /// device queue that ran at depth one for seven hundred and twenty-three
    /// completions, and a pipelined loop a lazy test double made look busy while
    /// it was not. So the claim is about traffic, asked directly.
    @Test("the second time the same block is wanted, the disk is not asked")
    func heldBlocksAreNotFetchedTwice() {
        withFileSystem { fs, disk in
            guard make(&fs, "one.bin") != nil else { return }

            fs.dropCache()

            let cold = disk.reads
            _ = fs.object(FSLayout.rootObject)
            #expect(disk.reads - cold == 1, "a record nobody has read has to be fetched")

            let warm = disk.reads
            for _ in 0..<20 { _ = fs.object(FSLayout.rootObject) }
            #expect(disk.reads == warm, "the same record was fetched again")

            // A whole name lookup, which reads the folder's record and then the
            // directory block the entry sits in. Only the first is the file
            // system's own, so the second time is cheaper and not free.
            let name = "one.bin" as StaticString

            fs.dropCache()
            let coldName = disk.reads
            #expect(fs.lookup(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                in    : FSLayout.rootObject
            ).object != nil)
            let once = disk.reads - coldName

            let warmName = disk.reads
            _ = fs.lookup(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                in    : FSLayout.rootObject
            ).object

            // Was 3 cold and 3 warm. Measured at 2 and 1.
            #expect(disk.reads - warmName < once)
        }
    }


    /// Bounded, and bounded where it says it is.
    ///
    /// A cache with no ceiling is a memory leak with good manners, and this one
    /// lives in the caller's scratch, so the bound is not a policy - it is how
    /// much room there is. Four blocks fit and the fifth pushes the first out,
    /// which is worth asserting because "deterministic" is the property that
    /// makes it safe in a server with no allocator.
    @Test("a fifth block pushes the first one out")
    func evictionIsBounded() {
        withFileSystem { fs, disk in

            // Sixty-four records to a table block, so these land in five
            // different ones.
            let spread: [UInt32] = [0, 64, 128, 192, 256]

            fs.dropCache()
            for index in spread.dropLast() { _ = fs.object(index) }

            // All four still in hand.
            let held = disk.reads
            for index in spread.dropLast() { _ = fs.object(index) }
            #expect(disk.reads == held, "four blocks do not fit in four slots")

            // The fifth evicts the oldest, which is the first.
            _ = fs.object(spread[4])

            let evicted = disk.reads
            _ = fs.object(spread[0])
            #expect(disk.reads - evicted == 1, "nothing was evicted, so nothing is bounded")
        }
    }


    // MARK: - How many at once

    /// The measurement, not the assumption.
    ///
    /// A pipelined read loop that leaves this at one is a loop that is not
    /// pipelining, and it looks exactly like one that is. The real machine taught
    /// that lesson the expensive way: the driver's queue was built, correct, and
    /// used to a depth of one for seven hundred and twenty-three completions,
    /// which nobody would have noticed without counting.
    ///
    /// `MemoryDisk` holds requests rather than answering inside `begin`, so this
    /// counts what was genuinely outstanding at once.
    @Test("reading several blocks keeps several reads in flight")
    func readingFillsThePipe() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "big.bin") else { return }

            let bytes = 16 * 4096
            let page = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            defer { page.deallocate() }
            page.initializeMemory(as: UInt8.self, repeating: 0xAB, count: bytes)

            for step in 0..<16 {
                let done = fs.write(file, at: UInt64(step) * 4096, from: page, count: 4096)
                #expect(done.status == .ok)
            }

            disk.resetDepth()

            // One call spanning sixteen blocks. There is something to overlap
            // here, and the whole point is that it is overlapped.
            let read = fs.read(file, at: 0, into: page, count: UInt64(bytes))

            #expect(read.status == .ok)
            #expect(read.bytes == UInt64(bytes))

            #expect(disk.highWater == BlockQueue.depth)
        }
    }


    /// And the bytes are right, which is the half a depth counter cannot see.
    /// Completions come back in whatever order the device chooses, so a loop that
    /// mixed up which slot was for which part of the file would still be busy and
    /// still be wrong.
    @Test("a pipelined read returns the file's own bytes, in order")
    func pipelinedBytesAreCorrect() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "pattern.bin") else { return }

            let bytes = 12 * 4096
            let source = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            let back   = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            defer { source.deallocate(); back.deallocate() }

            // Every byte says where it belongs, so a block landing in the wrong
            // place is visible rather than merely possible.
            for index in 0..<bytes {
                source.storeBytes(
                    of: UInt8(truncatingIfNeeded: index / 4096 + 1),
                    toByteOffset: index,
                    as: UInt8.self
                )
            }

            for step in 0..<12 {
                let done = fs.write(
                    file,
                    at   : UInt64(step) * 4096,
                    from : UnsafeRawPointer(source.advanced(by: step * 4096)),
                    count: 4096
                )
                #expect(done.status == .ok)
            }

            back.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)

            let read = fs.read(file, at: 0, into: back, count: UInt64(bytes))
            #expect(read.bytes == UInt64(bytes))

            for index in 0..<bytes {
                let want = source.loadUnaligned(fromByteOffset: index, as: UInt8.self)
                let got  = back.loadUnaligned(fromByteOffset: index, as: UInt8.self)

                if want != got {
                    Issue.record("byte \(index): expected \(want), got \(got)")
                    return
                }
            }
        }
    }


    /// A read that starts and ends inside one block has nothing to overlap, and
    /// must not pay for a pipeline to find that out.
    @Test("a read inside one block stays one request")
    func shortReadsStaySimple() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "small.bin") else { return }

            let page = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { page.deallocate() }
            page.initializeMemory(as: UInt8.self, repeating: 0xCD, count: 4096)

            let written = fs.write(file, at: 0, from: page, count: 4096)
            #expect(written.status == .ok)

            disk.resetDepth()

            let read = fs.read(file, at: 100, into: page, count: 200)
            #expect(read.bytes == 200)

            #expect(disk.highWater <= 1)
        }
    }


    /// Reading from the middle of a block, across several of them.
    ///
    /// Every earlier pipelined test starts at zero, where the offset into the
    /// first block is zero and so is the offset into every block after it - so a
    /// loop that forgot that offset entirely would pass all of them. This one
    /// starts part way in, which is where the first block's bytes begin at a
    /// place the copy has to be told about.
    @Test("a pipelined read that starts inside a block still lands correctly")
    func unalignedPipelinedRead() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "offset.bin") else { return }

            let bytes  = 12 * 4096
            let source = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            defer { source.deallocate() }

            // Every byte says which byte it is, so a copy that lands one block
            // early or late is visible.
            for index in 0..<bytes {
                source.storeBytes(
                    of: UInt8(truncatingIfNeeded: index * 7 + index / 4096),
                    toByteOffset: index,
                    as: UInt8.self
                )
            }

            for step in 0..<12 {
                let done = fs.write(
                    file,
                    at   : UInt64(step) * 4096,
                    from : UnsafeRawPointer(source.advanced(by: step * 4096)),
                    count: 4096
                )
                #expect(done.status == .ok)
            }

            let start = UInt64(1000)          // part way into the first block
            let span  = 4096 * 3 + 500        // and not a whole number of blocks

            let back = UnsafeMutableRawPointer.allocate(byteCount: Int(span), alignment: 8)
            defer { back.deallocate() }
            back.initializeMemory(as: UInt8.self, repeating: 0, count: Int(span))

            disk.resetDepth()

            let read = fs.read(file, at: start, into: back, count: UInt64(span))
            #expect(read.bytes == UInt64(span))
            #expect(disk.highWater > 1)

            for index in 0..<Int(span) {
                let want = source.loadUnaligned(
                    fromByteOffset: Int(start) + index, as: UInt8.self
                )
                let got = back.loadUnaligned(fromByteOffset: index, as: UInt8.self)

                if want != got {
                    Issue.record("byte \(index) of the read: expected \(want), got \(got)")
                    return
                }
            }
        }
    }


    /// A read that fails half way leaves requests with the device, and they have
    /// to be waited for before the loop gives up.
    ///
    /// A slot left outstanding would land its bytes in a buffer the *next* read
    /// is already using, so the damage does not show up in the read that failed -
    /// it shows up in the one after it, which is the hardest kind to trace.
    @Test("a failed pipelined read leaves nothing behind for the next one")
    func failureLeavesNothingOutstanding() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "torn.bin") else { return }

            let bytes  = 12 * 4096
            let source = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            let back   = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            defer { source.deallocate(); back.deallocate() }

            for index in 0..<bytes {
                source.storeBytes(
                    of: UInt8(truncatingIfNeeded: index / 4096 + 1),
                    toByteOffset: index,
                    as: UInt8.self
                )
            }

            for step in 0..<12 {
                let done = fs.write(
                    file,
                    at   : UInt64(step) * 4096,
                    from : UnsafeRawPointer(source.advanced(by: step * 4096)),
                    count: 4096
                )
                #expect(done.status == .ok)
            }

            // Give up with transfers still queued: the device answers nothing
            // once, which is the only way a caller ever leaves its loop with
            // requests outstanding.
            disk.swallowsOneAnswer = true

            let torn = fs.read(file, at: 0, into: back, count: UInt64(bytes))
            #expect(torn.status != .ok)

            // And it really did leave something behind, or the read below would
            // pass for the wrong reason.
            #expect(disk.uncollected > 0)

            // Now a read of a *different* stretch of the file. Different on
            // purpose: the leftovers hold the bytes of the blocks the torn read
            // asked for, so a read of the same range would be handed the right
            // answer by accident and prove nothing.
            let elsewhere = UInt64(5 * 4096)
            let span      = 5 * 4096

            back.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)

            let again = fs.read(file, at: elsewhere, into: back, count: UInt64(span))
            #expect(again.bytes == UInt64(span))

            for index in 0..<span {
                let want = source.loadUnaligned(
                    fromByteOffset: Int(elsewhere) + index, as: UInt8.self
                )
                let got = back.loadUnaligned(fromByteOffset: index, as: UInt8.self)

                if want != got {
                    Issue.record("byte \(index) after the failure: expected \(want), got \(got)")
                    return
                }
            }
        }
    }


    /// A completion that says the disk refused must not be copied out as though
    /// it had succeeded.
    ///
    /// The buffer for a refused read holds whatever was there before, so taking
    /// its bytes is not merely optimistic - it is handing back the previous
    /// request's data, or nothing, as this file's contents.
    @Test("a refused block in a pipelined read is not passed off as data")
    func refusedBlocksAreNotData() {
        withFileSystem { fs, disk in

            guard let file = make(&fs, "half.bin") else { return }

            let bytes  = 12 * 4096
            let source = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            let back   = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            defer { source.deallocate(); back.deallocate() }

            source.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

            for step in 0..<12 {
                let done = fs.write(
                    file,
                    at   : UInt64(step) * 4096,
                    from : UnsafeRawPointer(source.advanced(by: step * 4096)),
                    count: 4096
                )
                #expect(done.status == .ok)
            }

            back.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)

            // The disk stops answering part way through the read.
            disk.failAfter(2)

            let read = fs.read(file, at: 0, into: back, count: UInt64(bytes))

            #expect(read.status != .ok)
            #expect(read.bytes < UInt64(bytes))

            // And nothing past what it managed to read was touched, so a caller
            // that trusts `bytes` is not handed rubbish beyond it.
            var wrote = 0
            for index in Int(read.bytes)..<bytes
            where back.loadUnaligned(fromByteOffset: index, as: UInt8.self) != 0 {
                wrote += 1
            }

            #expect(wrote == 0)
        }
    }

}
