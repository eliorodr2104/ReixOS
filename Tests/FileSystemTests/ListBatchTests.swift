//
//  ListBatchTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// Listing a folder in one pass, and telling the end of it from a failure.
///
/// Two costs came off. The reads: asking one name at a time read the same
/// directory block once per name, and asking *by position* - which is what came
/// before the cursor - walked the folder from the front every time, so the
/// listing grew with the square of the folder. And the round trips, which is the
/// one that mattered: a name per call is a call per name, and every one of them
/// parks the caller.
///
/// The third thing that came off is not a cost. A listing used to answer one name
/// or *nothing*, and nothing was the end of the folder, and a folder that could
/// not be read, and a server that had gone. A caller told them apart by asking a
/// second question afterwards - which answers about the moment after, not the
/// moment in question.
@Suite("Listing in batches")
struct ListBatchTests {

    private static let sectors: UInt64 = 32768


    private func withFileSystem(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)

        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        body(&fs, disk)
    }


    /// `n<nnn>`, so a fixture can make hundreds of names in order.
    private func named(_ index: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        var name = InlineArray<8, UInt8>(repeating: 0)
        name[0] = UInt8(ascii: "n")
        name[1] = UInt8(0x30 + UInt8(index / 100 % 10))
        name[2] = UInt8(0x30 + UInt8(index / 10 % 10))
        name[3] = UInt8(0x30 + UInt8(index % 10))

        name.span.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!), 4)
        }
    }

    @discardableResult
    private func fill(
        _ fs: inout FileSystem<MemoryDisk>,
        _ count: Int,
        kind: FSKind = .file
    ) -> Bool {
        for index in 0..<count {
            var made = false
            named(index) { pointer, length in
                made = fs.create(
                    pointer, length: length, kind: kind, in: FSLayout.rootObject
                ).status == .ok
            }
            guard made else {
                Issue.record("name \(index) would not be made")
                return false
            }
        }
        return true
    }


    private func room(_ entries: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: entries * FSListEntry.width,
            alignment: 8
        )
    }

    private func entry(_ base: UnsafeMutableRawPointer, _ index: Int) -> FSListEntry {
        FSListEntry(reading: base.advanced(by: index * FSListEntry.width))
    }


    // MARK: - The cost

    @Test("ten names cost one pass and two reads")
    func tenNamesInOnePass() {
        withFileSystem { fs, disk in
            guard fill(&fs, 10) else { return }

            let base = room(32)
            defer { base.deallocate() }

            fs.dropCache()
            let before = disk.reads

            let batch = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 32
            )

            #expect(batch.status == .ok)
            #expect(batch.count == 10)
            #expect(batch.eof)

            // One directory block and one table block, and the table block is
            // read once for all ten records because it is one of the file
            // system's own and the cache holds it. Asking one name at a time was
            // twelve reads for the same ten names.
            #expect(disk.reads - before <= 2, "ten names cost \(disk.reads - before) reads")
        }
    }


    @Test("the names come back in the order they are in the folder")
    func orderIsKept() {
        withFileSystem { fs, _ in
            guard fill(&fs, 40) else { return }

            let base = room(64)
            defer { base.deallocate() }

            let batch = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 64
            )

            #expect(batch.count == 40)

            // Created in order and answered in order, because a folder is filled
            // front to back and the walk goes front to back.
            for index in 0..<batch.count {
                let read = entry(base, index)

                named(index) { pointer, length in
                    #expect(Int(read.length) == length)

                    let bytes = pointer.assumingMemoryBound(to: UInt8.self)
                    for at in 0..<length {
                        #expect(read.name[at] == bytes[at], "name \(index) byte \(at)")
                    }
                }
            }
        }
    }


    @Test("a folder longer than one batch is walked in batches, once each")
    func manyBatches() {
        withFileSystem { fs, _ in
            guard fill(&fs, 200) else { return }

            let base = room(32)
            defer { base.deallocate() }

            var cursor = UInt32(0)
            var seen   = 0
            var rounds = 0
            var ended  = false

            while rounds < 20 {
                rounds += 1

                let batch = fs.entries(
                    from: cursor, in: FSLayout.rootObject, into: base, capacity: 32
                )
                #expect(batch.status == .ok)

                seen += batch.count

                if batch.eof { ended = true; break }

                // A batch that is not the end came back full, or the cursor did
                // not move and the loop would not either.
                #expect(batch.count > 0)
                #expect(batch.next > cursor)

                cursor = batch.next
            }

            #expect(ended)
            #expect(seen == 200)
            #expect(rounds <= 8, "two hundred names in \(rounds) batches of thirty-two")
        }
    }


    // MARK: - Where a folder ends

    @Test("the end of a folder is said, not inferred from an empty answer")
    func eofIsAFact() {
        withFileSystem { fs, _ in
            let base = room(8)
            defer { base.deallocate() }

            // An empty folder: no entries *and* the end, in one answer. There is
            // nothing here to mistake for a failure.
            let empty = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 8
            )
            #expect(empty.status == .ok)
            #expect(empty.count == 0)
            #expect(empty.eof)

            // Exactly as many names as the batch holds. Full *and* the end,
            // which is the case that cannot be expressed by a count alone.
            guard fill(&fs, 8) else { return }

            let exact = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 8
            )
            #expect(exact.count == 8)
            #expect(exact.eof)

            // One more name than fits: full and *not* the end.
            let ninth = fs.create(
                UnsafeRawPointer(("extra" as StaticString).utf8Start),
                length: 5, kind: .file, in: FSLayout.rootObject
            )
            guard ninth.status == .ok else {
                Issue.record("the ninth name would not be made")
                return
            }

            let partial = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 8
            )
            #expect(partial.count == 8)
            #expect(!partial.eof)

            // And the one that did not fit is the first of the next batch.
            let rest = fs.entries(
                from: partial.next, in: FSLayout.rootObject, into: base, capacity: 8
            )
            #expect(rest.count == 1)
            #expect(rest.eof)
        }
    }


    @Test("a failure is not the end of a folder, and does not lose what was found")
    func failureIsNotEof() {
        withFileSystem { fs, disk in
            // Enough names to span more than one directory block, so the read
            // that fails is not the first one.
            guard fill(&fs, 200) else { return }

            let base = room(256)
            defer { base.deallocate() }

            fs.dropCache()

            // The disk stops answering part way through the walk.
            disk.failAfter(4)

            let batch = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 256
            )

            disk.recover()

            #expect(batch.status == .deviceFailed)

            // Not the end. A caller that read `eof` off a failure would stop
            // listing and say the folder had ended there.
            #expect(!batch.eof)

            // And whatever was found before the failure is still found: a
            // partial answer with a failure on it is more use than throwing away
            // the names that did read.
            #expect(batch.count > 0, "the names read before the failure were discarded")

            // Those names are real ones, in order.
            for index in 0..<batch.count {
                let read = entry(base, index)
                #expect(read.length == 4)
                #expect(read.name[0] == UInt8(ascii: "n"))
            }
        }
    }


    @Test("a folder that is not one, and a name that is not there")
    func refusalsAreNamed() {
        withFileSystem { fs, _ in
            let made = fs.create(
                UnsafeRawPointer(("a.bin" as StaticString).utf8Start),
                length: 5, kind: .file, in: FSLayout.rootObject
            )
            guard made.status == .ok else {
                Issue.record("create"); return
            }
            let file = made.object

            let base = room(8)
            defer { base.deallocate() }

            // A file is not a folder, and that is its own refusal rather than
            // an empty listing.
            let wrong = fs.entries(from: 0, in: file, into: base, capacity: 8)
            #expect(wrong.status == .wrongKind)
            #expect(!wrong.eof)
            #expect(wrong.count == 0)

            // And a slot nothing lives in.
            let missing = fs.entries(
                from: 0, in: fs.plan.objectCount - 1, into: base, capacity: 8
            )
            #expect(missing.status == .notFound)
            #expect(!missing.eof)
        }
    }


    @Test("no room asked for is no room used")
    func zeroCapacity() {
        withFileSystem { fs, _ in
            guard fill(&fs, 4) else { return }

            let base = room(1)
            defer { base.deallocate() }

            // Not a refusal and not the end: nothing was asked for, so nothing
            // was answered and the cursor did not move.
            let none = fs.entries(
                from: 0, in: FSLayout.rootObject, into: base, capacity: 0
            )
            #expect(none.status == .ok)
            #expect(none.count == 0)
            #expect(!none.eof)
            #expect(none.next == 0)
        }
    }


    // MARK: - The wire entry

    @Test("an entry survives being written and read")
    func entryRoundTrips() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: FSListEntry.width, alignment: 8
        )
        defer { raw.deallocate() }

        var letters = InlineArray<56, UInt8>(repeating: 0)
        for index in 0..<56 { letters[index] = UInt8(0x41 + index % 26) }

        FSListEntry(
            reference: 0x1234_5678,
            kind     : .container,
            length   : 56,
            name     : letters
        ).write(to: raw)

        let back = FSListEntry(reading: raw)

        #expect(back.reference == 0x1234_5678)
        #expect(back.kind == .container)
        #expect(back.length == 56)
        for index in 0..<56 { #expect(back.name[index] == letters[index]) }

        // The reserved pair is written zero, which is what makes it usable
        // later: a reader that skipped it cannot be broken by a writer that
        // starts filling it.
        #expect(raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self) == 0)

        // And the object is replaced in place, because the server changes one
        // word and not a whole entry.
        FSListEntry.rebadge(raw, 99)
        #expect(FSListEntry.reference(of: raw) == 99)
        #expect(FSListEntry(reading: raw).length == 56)
    }


    @Test("a length past the field is read as no name at all")
    func hostileLength() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: FSListEntry.width, alignment: 8
        )
        defer { raw.deallocate() }

        FSListEntry(reference: 1, kind: .file, length: 4).write(to: raw)

        // The bytes come out of a window somebody else can write, so a length of
        // two hundred is not a name that runs off the end of the entry.
        raw.storeBytes(of: UInt8(200), toByteOffset: 5, as: UInt8.self)
        #expect(FSListEntry(reading: raw).length == 0)

        raw.storeBytes(of: UInt8(57), toByteOffset: 5, as: UInt8.self)
        #expect(FSListEntry(reading: raw).length == 0)

        raw.storeBytes(of: UInt8(56), toByteOffset: 5, as: UInt8.self)
        #expect(FSListEntry(reading: raw).length == 56)

        // And a kind nothing means reads as a free slot rather than as whatever
        // number happened to be there.
        raw.storeBytes(of: UInt8(200), toByteOffset: 4, as: UInt8.self)
        #expect(FSListEntry(reading: raw).kind == .free)
    }


    // MARK: - What a caller does with a batch

    @Test("a verdict cannot be read without the entries that came with it")
    func stepCarriesTheCount() {
        let more = FSListBatchResult(status: .ok, count: 32, next: 32, eof: false)
        guard case .more(let carrying) = more.step else {
            Issue.record("a full batch mid-folder did not ask for more")
            return
        }
        #expect(carrying == 32)

        let ended = FSListBatchResult(status: .ok, count: 8, next: 8, eof: true)
        guard case .end(let last) = ended.step else {
            Issue.record("the end of a folder was not the end")
            return
        }
        #expect(last == 8)

        // Six names and then no disk. The count is part of the verdict, so a
        // caller cannot reach the failure without being handed what was found
        // before it - which is how a partial listing came to be thrown away.
        let broke = FSListBatchResult(status: .deviceFailed, count: 6, next: 6, eof: false)
        guard case .stopped(let found, let why) = broke.step else {
            Issue.record("a failure did not stop the walk")
            return
        }
        #expect(found == 6)
        #expect(why == .deviceFailed)

        // A failure that also claims the end is a failure. The status is judged
        // first, so nothing a server sets can end a caller's walk quietly.
        let contradictory = FSListBatchResult(
            status: .quarantined, count: 0, next: 0, eof: true
        )
        guard case .stopped(_, let held) = contradictory.step else {
            Issue.record("an end flag talked a failure away")
            return
        }
        #expect(held == .quarantined)
    }


    @Test("an error after the first batch is a verdict, with what was found attached")
    func errorAfterTheFirstBatch() {

        // At least one failure point has to leave names attached to the verdict.
        // Where exactly the read fails depends on the cache, so the point is
        // swept rather than guessed.
        var partialSeen = false

        for stop in 1...6 {
            withFileSystem { fs, disk in
                guard fill(&fs, 200) else { return }

                let base = room(200)
                defer { base.deallocate() }

                // The first batch goes through, so what follows is a failure
                // *after* a caller has already been told about names.
                let first = fs.entries(
                    from: 0, in: FSLayout.rootObject, into: base, capacity: 32
                )
                guard case .more(let found) = first.step else {
                    Issue.record("the first batch of two hundred names ended the folder")
                    return
                }
                #expect(found == 32)

                disk.failAfter(stop)

                // Room for every name that is left, so the walk has to reach the
                // last directory block and cannot fill up before the read that
                // fails - a batch that fills up early is entitled to answer
                // `more` without touching the disk again.
                let second = fs.entries(
                    from: first.next, in: FSLayout.rootObject, into: base, capacity: 168
                )

                disk.recover()

                switch second.step {
                    case .stopped(let found, let why):
                        #expect(why == .deviceFailed)
                        #expect(found < 168)
                        if found > 0 { partialSeen = true }

                    case .more(let found):
                        Issue.record("a disk that stopped answering asked for more (\(found))")

                    case .end:
                        Issue.record("a disk that stopped answering ended the folder")
                }
            }
        }

        #expect(partialSeen, "no failure point left names attached to the verdict")
    }


    @Test("the reply words carry four facts and not three")
    func replyShape() {
        let full = FileOperation.listed(.ok, count: 32, next: 400, eof: false)

        #expect(full.tag.label == FileOperation.list.rawValue)
        #expect(full.tag.length == 4)
        #expect(FileOperation.status(of: full) == .ok)
        #expect(FileOperation.listedCount(full) == 32)
        #expect(FileOperation.listedNext(full) == 400)
        #expect(!FileOperation.listedEnd(full))

        // The cursor gets a whole word now. It used to share one with the kind,
        // which capped a folder at sixteen million entries for no reason anybody
        // needed.
        let deep = FileOperation.listed(.ok, count: 1, next: UInt32.max, eof: true)
        #expect(FileOperation.listedNext(deep) == UInt32.max)
        #expect(FileOperation.listedEnd(deep))

        // A failure is a status *and* a count: a batch can find six names and
        // then lose the disk.
        let broken = FileOperation.listed(.deviceFailed, count: 6, next: 6, eof: false)
        #expect(FileOperation.status(of: broken) == .deviceFailed)
        #expect(FileOperation.listedCount(broken) == 6)
        #expect(!FileOperation.listedEnd(broken))
    }
}
