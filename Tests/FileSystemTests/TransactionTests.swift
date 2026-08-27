//
//  TransactionTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// The journal, from both ends: what it promises while the machine is running,
/// and what a machine that lost power in the middle of it finds.
///
/// What this replaces is a set of local rules about write order - "release the
/// blocks only after the record that stopped naming them is down" - each of which
/// was correct on its own and none of which composed. An operation touching a
/// bitmap block, an object record and a directory block had three orderings to
/// get right and no way to make the three of them one act. Now there is one
/// protocol, in one place, and every operation borrows it.
///
/// The interesting tests here are the ones that lose power. `CrashDisk` is what
/// makes them possible: a write is *accepted* into a queue and reaches the medium
/// only at a flush, so cutting the power is throwing the queue away rather than
/// hoping the model was right.
@Suite("Metadata transactions")
struct TransactionTests {

    /// 16 MiB, the same as the image the Makefile makes.
    private static let sectors: UInt64 = 32768

    private static let block = Int(FSLayout.blockSize)

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<CrashDisk>.scratchBytes,
            alignment: 8
        )
    }


    /// A formatted disk whose format is on the medium.
    private func withDisk(
        _ body: (inout FileSystem<CrashDisk>, CrashDisk) -> Void
    ) {
        let disk  = CrashDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        #expect(disk.flush() == .ok)

        body(&fs, disk)
    }


    /// Mounts the medium as it stands, through a device with no memory of the
    /// crash.
    ///
    /// A fresh device every time, and a fresh file system: reusing the one that
    /// crashed would carry its cached blocks and its idea of the journal across
    /// the power cut, which is precisely what a power cut takes away.
    private func remount(
        _ disk: CrashDisk,
        _ body: (inout FileSystem<CrashDisk>, FSMount) -> Void
    ) {
        let after = CrashDisk(restarting: disk)
        let space = scratch()
        defer { space.deallocate() }

        let attempt = FileSystem.mount(after, scratch: space)

        guard var mounted = attempt.disk else {
            Issue.record("the crashed disk would not mount: \(attempt.found)")
            return
        }

        body(&mounted, attempt.found)
    }


    private func named(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }


    // MARK: - The header on the disk

    @Test("a journal header survives being written and read")
    func headerRoundTrips() {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { raw.deallocate() }

        var header = FSJournal()
        header.state       = .committed
        header.generation  = 0x1234_5678_9ABC_DEF0
        header.recordCount = 3
        header.targets[0]  = 100; header.checksums[0] = 0xAAAA
        header.targets[1]  = 200; header.checksums[1] = 0xBBBB
        header.targets[2]  = 300; header.checksums[2] = 0xCCCC

        header.write(to: raw)

        #expect(FSJournal.isWhole(raw))

        let back = FSJournal(reading: raw)
        #expect(back.state == .committed)
        #expect(back.generation == 0x1234_5678_9ABC_DEF0)
        #expect(back.recordCount == 3)
        #expect(back.targets[1] == 200)
        #expect(back.checksums[2] == 0xCCCC)
    }


    @Test("a header with one byte changed is not a header")
    func headerChecksumBites() {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { raw.deallocate() }

        var header = FSJournal()
        header.state       = .committed
        header.recordCount = 1
        header.targets[0]  = 100
        header.write(to: raw)

        #expect(FSJournal.isWhole(raw))

        // Every field is covered, and the checksum field itself is read as zero
        // so the block can carry its own.
        for offset in [
            FSJournal.Header.state,
            FSJournal.Header.generation,
            FSJournal.Header.recordCount,
            FSJournal.Header.records,
            FSJournal.Header.records + 4
        ] {
            let was = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            raw.storeBytes(of: was ^ 0x01, toByteOffset: offset, as: UInt8.self)

            #expect(!FSJournal.isWhole(raw), "offset \(offset)")

            raw.storeBytes(of: was, toByteOffset: offset, as: UInt8.self)
        }

        #expect(FSJournal.isWhole(raw))

        // A block of zeroes is not an empty journal. It is a block that has never
        // been one, and reading it as empty would be reading a blank disk as a
        // finished transaction.
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Self.block)
        #expect(!FSJournal.isWhole(raw))
    }


    @Test("a record may not name the front of the disk")
    func targetsAreBounded() {
        guard let plan = FSLayout.Plan(sectorCount: Self.sectors, sectorSize: 512) else {
            Issue.record("no plan"); return
        }

        var header = FSJournal()
        header.recordCount = 1

        // Replaying an image over the journal header would rewrite the thing that
        // says what to replay; over a superblock, it would put a bitmap block
        // where the layout lives.
        for target in [
            UInt32(0), 1, FSLayout.journalHeaderBlock, FSLayout.journalStart,
            FSLayout.reservedBlocks - 1, plan.totalBlocks, UInt32.max
        ] {
            header.targets[0] = target
            #expect(!header.targetsFit(plan), "target \(target)")
        }

        header.targets[0] = FSLayout.reservedBlocks
        #expect(header.targetsFit(plan))

        header.targets[0] = plan.totalBlocks - 1
        #expect(header.targetsFit(plan))
    }


    // MARK: - While the machine is running

    @Test("a committed transaction reaches the home blocks and an aborted one does not")
    func commitAndAbort() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart
            let before = Self.blockBytes(&fs, target)

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block)

            // Aborted: the after-image is in the journal and the home block never
            // hears about it.
            #expect(fs.begin() == .ok)
            #expect(fs.stageStructuralBlock(target, from: UnsafeRawPointer(payload)) == .ok)
            fs.abort()

            #expect(Self.blockBytes(&fs, target) == before)

            // Committed: it does.
            #expect(fs.begin() == .ok)
            #expect(fs.stageStructuralBlock(target, from: UnsafeRawPointer(payload)) == .ok)
            #expect(fs.commit() == .ok)

            let after = Self.blockBytes(&fs, target)
            #expect(after != before)
            #expect(after[0] == 0x5A)
            #expect(after[Self.block - 1] == 0x5A)

            // And the journal is empty again, so the next transaction may open.
            #expect(fs.begin() == .ok)
            fs.abort()

            _ = disk
        }
    }


    @Test("a read inside a transaction sees what the transaction wrote")
    func readsSeeStagedWrites() {
        withDisk { fs, _ in
            let target = fs.plan.bitmapStart

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x77, count: Self.block)

            #expect(fs.begin() == .ok)
            #expect(fs.stageStructuralBlock(target, from: UnsafeRawPointer(payload)) == .ok)

            // The home block still holds the old bytes. Without this the bitmap
            // allocator would read back what it had just replaced, which is two
            // objects being handed the same block.
            #expect(Self.blockBytes(&fs, target)[0] == 0x77)

            // And the medium disagrees, which is the whole point.
            #expect(Self.rawBytes(&fs, target)[0] != 0x77)

            fs.abort()

            // Abandoned, so the reader is back on the home block.
            #expect(Self.blockBytes(&fs, target)[0] != 0x77)
        }
    }


    @Test("the same block staged twice takes one slot and one home write")
    func stagingCoalesces() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }

            #expect(fs.begin() == .ok)

            let staged = disk.writes

            for round in 0..<8 {
                payload.initializeMemory(
                    as: UInt8.self, repeating: UInt8(round), count: Self.block
                )
                #expect(fs.stageStructuralBlock(target, from: UnsafeRawPointer(payload)) == .ok)
            }

            // Nothing has reached the medium yet, whatever those eight rounds
            // said: staging is a copy into memory.
            #expect(disk.writes == staged)

            let writesBefore = disk.writes
            #expect(fs.commit() == .ok)

            // One payload, three headers - prepared, committed, empty - and one
            // home write. Eight separate images would be eight of each.
            #expect(disk.writes - writesBefore == 5)

            // The last one is what is there.
            #expect(Self.blockBytes(&fs, target)[0] == 7)
        }
    }


    @Test("an operation that would need a seventeenth image is refused")
    func journalHasABound() {
        withDisk { fs, _ in
            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x11, count: Self.block)

            #expect(fs.begin() == .ok)

            for index in 0..<FSJournal.capacity {
                let target = fs.plan.dataStart + UInt32(index)
                #expect(fs.stageStructuralBlock(
                    target, from: UnsafeRawPointer(payload)
                ) == .ok, "image \(index)")
            }

            // The seventeenth. Refused here, before the commit, and not truncated
            // at it: a transaction that can be cut short is not one.
            #expect(fs.stageStructuralBlock(
                fs.plan.dataStart + UInt32(FSJournal.capacity),
                from: UnsafeRawPointer(payload)
            ) == .tooManyChanges)

            #expect(fs.transactionOverflows == 1)

            fs.abort()

            // Nothing this format does gets near sixteen, so the counter is a
            // report about the design and not about the disk.
            #expect(fs.transactionOverflows == 1)
        }
    }


    @Test("a transaction cannot begin over another, and an unmount cannot cut one short")
    func oneWriterAtATime() {
        withDisk { fs, _ in
            #expect(fs.begin() == .ok)
            #expect(fs.begin() == .busy)

            // A clean mark over an unfinished transaction is a disk that says it
            // was shut down tidily and holds a journal saying otherwise.
            #expect(fs.unmount() == .busy)

            fs.abort()
            #expect(fs.unmount() == .ok)
        }
    }


    // MARK: - After the power goes

    /// The two things that must never both be true of one object after a crash.
    private func doneOrUndone(
        _ fs: inout FileSystem<CrashDisk>,
        _ name: StaticString,
        _ object: UInt32
    ) -> Bool {

        var found: UInt32? = nil
        named(name) { pointer, length in
            found = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
        }

        let live = fs.object(object)?.kind == .file

        return (found != nil && live) || (found == nil && !live)
    }


    @Test("a create inside a transaction is done or not done, whenever the power goes")
    func createIsIndivisible() {
        let name = "orphan.bin" as StaticString

        // Every point the machine can stop at, one run each. The device refuses
        // from the nth request onward and then the power goes, so whatever had
        // been flushed is on the medium and everything else is gone - which is
        // exactly what a crash is.
        for stop in 1...40 {
            let disk  = CrashDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format"); return
            }
            #expect(disk.flush() == .ok)

            // Which slot the create will take, so the record can be looked at
            // afterwards whether or not the name reached the disk.
            let slot = UInt32(1)

            disk.failAfter(stop)

            if fs.begin() == .ok {
                named(name) { pointer, length in
                    _ = fs.create(
                        pointer, length: length, kind: .file, in: FSLayout.rootObject
                    )
                }
                _ = fs.commit()
            }

            disk.powerCut()

            let after = CrashDisk(restarting: disk)
            let two   = scratch()
            defer { two.deallocate() }

            let attempt = FileSystem.mount(after, scratch: two)

            guard var again = attempt.disk else {
                // A disk this cannot mount is a separate failure, and a crash
                // must not produce one: both superblocks are whole at every
                // point, because they are never written in the same breath.
                Issue.record("stop \(stop): the crashed disk would not mount, \(attempt.found)")
                continue
            }

            #expect(doneOrUndone(&again, name, slot),
                    "stop \(stop): a live record that nothing names survived the cut")
        }
    }


    @Test("a journal found prepared is thrown away")
    func preparedIsDiscarded() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart
            let before = Self.rawBytes(&fs, target)

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block)

            #expect(fs.begin() == .ok)
            #expect(fs.stageStructuralBlock(target, from: UnsafeRawPointer(payload)) == .ok)

            // The images and a prepared header, made durable, and then the power
            // goes before the committed one. Nothing on the disk depends on them.
            var header = FSJournal()
            header.state       = .prepared
            header.generation  = 1
            header.recordCount = 1
            header.targets[0]  = target
            header.checksums[0] = FSChecksum.over(payload, count: Self.block)

            Self.putHeader(&fs, header)
            #expect(disk.flush() == .ok)

            remount(disk) { again, found in
                #expect(isOK(found))

                // The home block is untouched, and the journal is empty again.
                #expect(Self.rawBytes(&again, target) == before)
                #expect(again.begin() == .ok)
                again.abort()
            }
        }
    }


    @Test("a journal found committed is finished, however many times it is found")
    func committedIsReplayed() {
        withDisk { fs, disk in
            // The first object-table block, copied as it is and then changed at
            // one free record. A previous fixture replayed 0x5A over a whole
            // metadata block. That correctly made the next mount refuse the
            // disk; it did not test replay. This after-image is a real, valid
            // structural block whose observable free-record generation differs.
            let target = fs.plan.tableStart
            let changedGeneration: UInt32 = 0xC0DE_CAFE

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }

            #expect(fs.readRawBlock(target, into: payload) == .ok)

            let freeOffset = Int(FSLayout.objectSize)
            var free = FSObject(reading: payload.advanced(by: freeOffset))
            #expect(free.standing == .free)
            free.generation = changedGeneration
            free.write(to: payload.advanced(by: freeOffset))
            #expect(FSObject(reading: payload.advanced(by: freeOffset)).fits(fs.plan))

            // An image in the journal, a committed header, and no home write:
            // the power went between step eight and step nine.
            #expect(fs.writeRawBlock(
                FSJournal.payload(of: 0), from: UnsafeRawPointer(payload)
            ) == .ok)

            // Stamped with the mount being served, which is what a journal the
            // crashed mount left behind carries. See `JournalArenaTests`.
            guard let stamp = FSJournal.stamp(
                mount: fs.superblockGeneration, step: 1
            ) else { Issue.record("no stamp"); return }

            var header = FSJournal()
            header.state        = .committed
            header.generation   = stamp
            header.recordCount  = 1
            header.targets[0]   = target
            header.checksums[0] = FSChecksum.over(payload, count: Self.block)

            Self.putHeader(&fs, header)
            #expect(disk.flush() == .ok)

            let crashed = CrashDisk(restarting: disk)

            // First mount: replayed.
            let one = scratch()
            defer { one.deallocate() }

            guard var first = FileSystem.mount(crashed, scratch: one).disk else {
                Issue.record("first mount"); return
            }
            #expect(first.object(1)?.standing == .free)
            #expect(first.object(1)?.generation == changedGeneration)
            #expect(crashed.flush() == .ok)

            // The same journal again, re-stamped for the mount that will read it:
            // a whole-block image applied twice is applied once.
            guard let again = FSJournal.stamp(
                mount: first.superblockGeneration, step: 1
            ) else { Issue.record("no stamp"); return }

            header.generation = again
            Self.putHeader(&first, header)
            #expect(crashed.flush() == .ok)

            let restarted = CrashDisk(restarting: crashed)
            let two = scratch()
            defer { two.deallocate() }

            guard var second = FileSystem.mount(restarted, scratch: two).disk else {
                Issue.record("second mount"); return
            }

            #expect(second.object(1)?.standing == .free)
            #expect(second.object(1)?.generation == changedGeneration)
            #expect(second.begin() == .ok)
            second.abort()
        }
    }


    @Test("a payload that does not check out holds the volume still")
    func brokenPayloadQuarantines() {
        withDisk { fs, disk in
            let target = fs.plan.tableStart

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block)

            #expect(fs.writeRawBlock(
                FSJournal.payload(of: 0), from: UnsafeRawPointer(payload)
            ) == .ok)

            guard let stamp = FSJournal.stamp(
                mount: fs.superblockGeneration, step: 1
            ) else { Issue.record("no stamp"); return }

            var header = FSJournal()
            header.state        = .committed
            header.generation   = stamp
            header.recordCount  = 1
            header.targets[0]   = target

            // The checksum of something else. A payload that does not match is a
            // transaction this cannot finish, and half of one is worse than none.
            header.checksums[0] = FSChecksum.over(payload, count: Self.block) ^ 1

            Self.putHeader(&fs, header)
            #expect(disk.flush() == .ok)

            let crashed = CrashDisk(restarting: disk)
            let space   = scratch()
            defer { space.deallocate() }

            let attempt = FileSystem.mount(crashed, scratch: space)

            #expect(attempt.disk == nil)
            #expect(isCorrupt(attempt.found))
        }
    }


    @Test("a journal naming the front of the disk holds the volume still")
    func hostileTargetQuarantines() {
        withDisk { fs, disk in
            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block)

            #expect(fs.writeRawBlock(
                FSJournal.payload(of: 0), from: UnsafeRawPointer(payload)
            ) == .ok)

            var header = FSJournal()
            header.state        = .committed
            header.generation   = 1
            header.recordCount  = 1
            header.targets[0]   = FSLayout.superblockA
            header.checksums[0] = FSChecksum.over(payload, count: Self.block)

            Self.putHeader(&fs, header)
            #expect(disk.flush() == .ok)

            let crashed = CrashDisk(restarting: disk)
            let space   = scratch()
            defer { space.deallocate() }

            let attempt = FileSystem.mount(crashed, scratch: space)

            #expect(attempt.disk == nil)
            #expect(isCorrupt(attempt.found))

            // And the superblock it named is untouched.
            #expect(crashed.byte(at: FSSuperblockField.commit) != 0x5A)
        }
    }


    // MARK: - Whichever writes survived

    @Test("no ordering of the queue leaves a disk that cannot be mounted")
    func anySurvivorsStillMount() {
        // The other half of what a crash is: a device holding several accepted
        // writes may land any subset of them, in any order. What must hold for
        // every one of those is that the disk still mounts - the two superblocks
        // are never written in the same breath, so one of them is always whole.
        let modes: [CrashDisk.Survivors] = [
            .nothing, .everything,
            .forwardPrefix(1), .forwardPrefix(3), .forwardPrefix(7),
            .reversePrefix(1), .reversePrefix(3),
            .single(0), .single(2),
            .permuted(1), .permuted(2), .permuted(9)
        ]

        for mode in modes {
            let disk  = CrashDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format"); return
            }
            #expect(disk.flush() == .ok)

            let name = "half.bin" as StaticString

            #expect(fs.begin() == .ok)
            named(name) { pointer, length in
                _ = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject)
            }

            // Cut in the middle of the commit, so the queue holds part of it: the
            // images are written, the prepared header is written, and none of it
            // has been flushed.
            var header = FSJournal()
            header.state       = .prepared
            header.generation  = 1
            header.recordCount = 1
            header.targets[0]  = fs.plan.tableStart

            Self.putHeader(&fs, header)
            disk.powerCut(keeping: mode)

            let after = CrashDisk(restarting: disk)
            let two   = scratch()
            defer { two.deallocate() }

            let attempt = FileSystem.mount(after, scratch: two)

            guard var again = attempt.disk else {
                Issue.record("\(mode): the disk would not mount, \(attempt.found)")
                continue
            }

            // And whatever survived, the file is either there or not there.
            #expect(doneOrUndone(&again, name, 1), "\(mode)")
        }
    }


    @Test("an abandoned transaction leaves the medium byte for byte as it was")
    func abortChangesNothingStable() {
        withDisk { fs, disk in
            let before = disk.snapshot()

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block)

            #expect(fs.begin() == .ok)

            named("gone.bin") { pointer, length in
                _ = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject)
            }
            #expect(fs.stageStructuralBlock(
                fs.plan.bitmapStart, from: UnsafeRawPointer(payload)
            ) == .ok)

            fs.abort()

            // The journal payloads have moved, and nothing else has: the images
            // are written but no home block was touched, so a machine that lost
            // power here would find a journal it throws away.
            #expect(disk.flush() == .ok)

            let after = disk.snapshot()

            let front = Int(FSLayout.reservedBlocks) * Self.block
            #expect(Array(after[front...]) == Array(before[front...]))

            // A device that stops answering and then answers again does not
            // change that: the transaction was never promised.
            disk.failAfter(1)
            #expect(fs.begin() != .ok || fs.commit() == .ok)
            disk.recover()
        }
    }


    // MARK: - Every operation, at every stopping point

    /// A small disk, so a sweep of forty stopping points per operation is a
    /// second and not a minute.
    private static let smallSectors: UInt64 = 4096      // 2 MiB

    /// Runs `operation` once for every point the machine can stop at, and asks
    /// the disk afterwards whether it is one of the two states it is allowed to
    /// be in.
    ///
    /// The stop is a device that refuses from its nth request onward followed by
    /// a power cut, which together are what a crash is: whatever had been flushed
    /// is on the medium and everything the device had merely accepted is gone.
    /// Every one of the thirteen steps of the commit protocol, and every write of
    /// every operation before it, falls inside the sweep.
    ///
    /// What is checked after every one of them is the same six things, because
    /// they are the six a half-finished operation used to be able to leave: a
    /// disk that will not mount, a journal still holding a promise, blocks owned
    /// and free, blocks owned twice, a container's room that does not add up, and
    /// a name pointing at a free record. `also` adds whatever "done or not done"
    /// means for the operation under test.
    private func sweep(
        _ what   : String,
        upTo limit: Int = 44,
        prepare  : (inout FileSystem<CrashDisk>) -> Void = { _ in },
        operation: (inout FileSystem<CrashDisk>) -> Void,
        also     : (inout FileSystem<CrashDisk>, Int) -> Void = { _, _ in },
        done     : ((inout FileSystem<CrashDisk>) -> Bool)? = nil
    ) {
        // Both outcomes have to actually happen, or the sweep is asserting
        // something about runs that never reached the operation. Forty stops that
        // all read "not done" is a device failing at its first read forty times.
        var finished = 0
        var undone   = 0

        for stop in 1...limit {
            let disk  = CrashDisk(sectors: Self.smallSectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("\(what): format")
                return
            }

            prepare(&fs)
            #expect(disk.flush() == .ok, "\(what) stop \(stop): the fixture would not settle")

            disk.failAfter(stop)
            operation(&fs)
            disk.powerCut()

            let after = CrashDisk(restarting: disk)
            let two   = scratch()
            defer { two.deallocate() }

            let attempt = FileSystem.mount(after, scratch: two)

            guard var again = attempt.disk else {
                Issue.record("\(what) stop \(stop): would not mount, \(attempt.found)")
                continue
            }

            // The journal is empty, which means whatever it was holding was
            // finished or thrown away before a single request was served.
            #expect(again.begin() == .ok, "\(what) stop \(stop): the journal was left holding something")
            again.abort()

            let findings = again.scan(.everything)

            #expect(findings.complete,        "\(what) stop \(stop)")
            #expect(findings.ownedButFree == 0, "\(what) stop \(stop): blocks owned and free")
            #expect(findings.claimedTwice == 0, "\(what) stop \(stop): blocks owned twice")
            #expect(findings.wrongQuota   == 0, "\(what) stop \(stop): room that does not add up")
            #expect(findings.strayNames   == 0, "\(what) stop \(stop): a name pointing at nothing")
            #expect(findings.impossible   == 0, "\(what) stop \(stop): a record that cannot be true")

            also(&again, stop)

            if let done {
                if done(&again) { finished += 1 } else { undone += 1 }
            }
        }

        guard done != nil else { return }

        #expect(finished > 0, "\(what): no stopping point finished the operation")
        #expect(undone   > 0, "\(what): no stopping point stopped it short")
    }


    /// Whether `name` is in the root and, if it is, whether it points at a live
    /// record. `nil` when the name is not there.
    private func liveNamed(
        _ fs: inout FileSystem<CrashDisk>,
        _ name: StaticString
    ) -> Bool? {
        var found: UInt32? = nil
        named(name) { pointer, length in
            found = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
        }

        guard let found else { return nil }
        return fs.object(found)?.kind != .free
    }


    private func fixtureFile(
        _ fs: inout FileSystem<CrashDisk>,
        _ name: StaticString,
        blocks: Int
    ) -> UInt32? {
        var made: UInt32? = nil
        named(name) { pointer, length in
            let result = fs.create(
                pointer, length: length, kind: .file, in: FSLayout.rootObject
            )
            if result.status == .ok { made = result.object }
        }

        guard let object = made, blocks > 0 else { return made }

        let bytes   = Int(FSLayout.blockSize) * blocks
        let payload = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

        guard fs.write(
            object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(bytes)
        ).status == .ok else { return nil }

        return object
    }


    @Test("making something is done or not done")
    func createSurvives() {
        sweep("create", operation: { fs in
            named("made.bin") { pointer, length in
                _ = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject)
            }
        }, also: { fs, _ in
            // Either the name is there pointing at a live record, or it is not
            // there at all. A name pointing at a free slot is `strayNames` above;
            // a live record nothing names is what the sweep exists for.
            if let live = liveNamed(&fs, "made.bin") { #expect(live) }
        }, done: { fs in
            liveNamed(&fs, "made.bin") != nil
        })

        sweep("create folder", operation: { fs in
            named("dir") { pointer, length in
                _ = fs.create(pointer, length: length, kind: .folder, in: FSLayout.rootObject)
            }
        })
    }


    @Test("making a container is done or not done, and its room adds up either way")
    func createContainerSurvives() {
        sweep("createContainer", operation: { fs in
            named("room") { pointer, length in
                _ = fs.createContainer(pointer, length: length, quota: 40, in: FSLayout.rootObject)
            }
        }, also: { fs, _ in
            if let live = liveNamed(&fs, "room") { #expect(live) }
        })
    }


    @Test("moving room between containers is done or not done")
    func grantQuotaSurvives() {
        sweep("grantQuota", prepare: { fs in
            named("inner") { pointer, length in
                _ = fs.createContainer(
                    pointer, length: length, quota: 20, in: FSLayout.rootObject
                )
            }
        }, operation: { fs in
            guard let child = { () -> UInt32? in
                var found: UInt32? = nil
                named("inner") { pointer, length in
                    found = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
                }
                return found
            }() else { return }

            _ = fs.grantQuota(10, from: FSLayout.rootObject, to: child)
        })
    }


    @Test("taking something away is done or not done")
    func removeSurvives() {
        sweep("remove", prepare: { fs in
            _ = fixtureFile(&fs, "doomed.bin", blocks: 2)
        }, operation: { fs in
            named("doomed.bin") { pointer, length in
                _ = fs.remove(pointer, length: length, from: FSLayout.rootObject)
            }
        }, also: { fs, _ in
            if let live = liveNamed(&fs, "doomed.bin") { #expect(live) }
        }, done: { fs in
            liveNamed(&fs, "doomed.bin") == nil
        })
    }


    @Test("moving a name is done or not done, and never leaves it in both places")
    func relocateSurvives() {
        sweep("relocate", prepare: { fs in
            _ = fixtureFile(&fs, "here.bin", blocks: 1)
            named("there") { pointer, length in
                _ = fs.create(pointer, length: length, kind: .folder, in: FSLayout.rootObject)
            }
        }, operation: { fs in
            var target: UInt32? = nil
            named("there") { pointer, length in
                target = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let target else { return }

            named("here.bin") { from, fromLength in
                named("gone.bin") { to, toLength in
                    _ = fs.relocate(
                        from, length: fromLength, from: FSLayout.rootObject,
                        to: target, as: to, length: toLength
                    )
                }
            }
        }, also: { fs, stop in
            // In exactly one place. The old write order could leave it in two,
            // and called that an acceptable outcome to be tidied later.
            var target: UInt32? = nil
            named("there") { pointer, length in
                target = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }

            var here: UInt32? = nil
            named("here.bin") { pointer, length in
                here = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }

            var moved: UInt32? = nil
            if let target {
                named("gone.bin") { pointer, length in
                    moved = fs.lookup(pointer, length: length, in: target).object
                }
            }

            #expect(!(here != nil && moved != nil), "relocate stop \(stop): named twice")
        })
    }


    @Test("growing a file is done or not done, and never claims bytes it has not got")
    func growSurvives() {
        let block = Int(FSLayout.blockSize)

        sweep("grow", prepare: { fs in
            _ = fixtureFile(&fs, "grows.bin", blocks: 1)
        }, operation: { fs in
            var object: UInt32? = nil
            named("grows.bin") { pointer, length in
                object = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let object else { return }

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: block * 3, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x77, count: block * 3)

            _ = fs.write(
                object, at: UInt64(block), from: UnsafeRawPointer(payload),
                count: UInt64(block * 3)
            )
        }, also: { fs, stop in
            var object: UInt32? = nil
            named("grows.bin") { pointer, length in
                object = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let object, let record = fs.object(object) else { return }

            // One block or four, and nothing in between: the size and the blocks
            // that hold it are one act. A size of four blocks over one block of
            // extents is the forbidden state - a file claiming bytes nobody wrote.
            #expect(record.size == UInt64(block) || record.size == UInt64(block * 4),
                    "grow stop \(stop): size \(record.size)")

            #expect(UInt64(record.blocks) * FSLayout.blockSize >= record.size,
                    "grow stop \(stop): a size past its blocks")
        }, done: { fs in
            var object: UInt32? = nil
            named("grows.bin") { pointer, length in
                object = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let object, let record = fs.object(object) else { return false }

            return record.size == UInt64(block * 4)
        })
    }


    @Test("replacing and shortening are done or not done")
    func replaceAndTruncateSurvive() {
        let block = Int(FSLayout.blockSize)

        sweep("replace", prepare: { fs in
            _ = fixtureFile(&fs, "swap.bin", blocks: 4)
        }, operation: { fs in
            var object: UInt32? = nil
            named("swap.bin") { pointer, length in
                object = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let object else { return }

            let payload = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 8)
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x22, count: block)

            _ = fs.write(
                object, at: 0, from: UnsafeRawPointer(payload),
                count: UInt64(block), replacing: true
            )
        })

        sweep("truncate", prepare: { fs in
            _ = fixtureFile(&fs, "cut.bin", blocks: 4)
        }, operation: { fs in
            var object: UInt32? = nil
            named("cut.bin") { pointer, length in
                object = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let object else { return }

            _ = fs.truncate(object, to: UInt64(block))
        })
    }


    @Test("putting a file back together is done or not done")
    func compactSurvives() {
        let block = Int(FSLayout.blockSize)

        sweep("compact", upTo: 60, prepare: { fs in
            // Three files side by side, the middle one grown after the third has
            // taken the blocks it would have grown into: two extents.
            _ = fixtureFile(&fs, "a.bin", blocks: 1)
            let middle = fixtureFile(&fs, "b.bin", blocks: 1)
            _ = fixtureFile(&fs, "c.bin", blocks: 1)

            guard let middle else { return }

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: block * 2, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x33, count: block * 2)

            _ = fs.write(
                middle, at: UInt64(block), from: UnsafeRawPointer(payload),
                count: UInt64(block * 2)
            )
        }, operation: { fs in
            var object: UInt32? = nil
            named("b.bin") { pointer, length in
                object = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
            }
            guard let object else { return }

            _ = fs.compact(object)
        })
    }


    @Test("renaming the machine is done or not done")
    func renameSurvives() {
        sweep("nameMachine", upTo: 12, operation: { fs in
            let name = "elsewhere" as StaticString
            _ = fs.setMachineName(
                UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount
            )
        }, also: { fs, stop in
            let out = UnsafeMutableRawPointer.allocate(
                byteCount: FSLayout.machineNameLimit, alignment: 8
            )
            defer { out.deallocate() }

            let length = fs.machineName(into: out)
            let bytes  = out.assumingMemoryBound(to: UInt8.self)

            var read = ""
            for index in 0..<length { read.append(Character(UnicodeScalar(bytes[index]))) }

            // The old name or the new one, and never half of either: the
            // superblock is written to the copy that is not being read from.
            #expect(read == "reix" || read == "elsewhere", "rename stop \(stop): \(read)")
        }, done: { fs in
            let out = UnsafeMutableRawPointer.allocate(
                byteCount: FSLayout.machineNameLimit, alignment: 8
            )
            defer { out.deallocate() }

            return fs.machineName(into: out) == 9
        })
    }


    @Test("putting the block map right is done or not done")
    func repairSurvives() {
        sweep("repair", prepare: { fs in
            _ = fixtureFile(&fs, "kept.bin", blocks: 2)

            // Blocks marked used that nothing owns, which is what a repair is
            // for. Committed on purpose: it is the only way to reach the state.
            #expect(fs.begin() == .ok)
            _ = fs.allocateRun(3)
            #expect(fs.commit() == .ok)
        }, operation: { fs in
            _ = fs.putRight()
        })
    }


    // MARK: - Reading blocks in tests

    /// One block as the file system sees it, transaction and cache included.
    private static func blockBytes(
        _ fs: inout FileSystem<CrashDisk>,
        _ index: UInt32
    ) -> [UInt8] {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 8)
        defer { raw.deallocate() }

        guard fs.readBlock(index, into: raw) == .ok else { return [] }

        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: block))
    }

    /// One block as it really is, with nothing in the way.
    private static func rawBytes(
        _ fs: inout FileSystem<CrashDisk>,
        _ index: UInt32
    ) -> [UInt8] {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 8)
        defer { raw.deallocate() }

        guard fs.readRawBlock(index, into: raw) == .ok else { return [] }

        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: block))
    }

    /// Puts a header on the disk behind the file system's back, which is how a
    /// crash at a chosen step is arranged.
    private static func putHeader(_ fs: inout FileSystem<CrashDisk>, _ header: FSJournal) {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 8)
        defer { raw.deallocate() }

        header.write(to: raw)
        _ = fs.writeRawBlock(FSLayout.journalHeaderBlock, from: UnsafeRawPointer(raw))
    }
}
