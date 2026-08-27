//
//  FailClosedTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Foundation
import Testing
import ReixABI
@testable import ReixFS

/// What a transaction does when one of its own writes is refused.
///
/// The journal made "all of it or none of it" true of the *medium*. It did not
/// make it true of the answer: a staging call could be refused, the operation
/// around it could drop the refusal on the floor, and `finish(.ok)` would then
/// commit whatever had happened to get staged. The worst of them was a truncate
/// that reported success while the blocks it had stopped naming were never given
/// back, because `releaseRun` answered `false` and the caller turned that into
/// `ok`.
///
/// Three things close it, and all three are tested here. Every structural
/// mutation returns its `FSStatus` and every caller propagates it; allocations
/// answer with a reason rather than `nil`; and `FSTransaction.stickyFailure`
/// makes a refused staging call fatal to the whole transaction whether or not
/// anybody above it noticed.
@Suite("Transactions that fail closed")
struct FailClosedTests {

    /// 16 MiB, the same as the image the Makefile makes.
    private static let sectors: UInt64 = 32768

    /// 256 MiB, which is the smallest disk with two bitmap blocks and so the
    /// smallest on which a run can want two after-images.
    private static let wideSectors: UInt64 = 524288

    private static let block = Int(FSLayout.blockSize)


    private func scratch<D: BlockDevice>(_: D.Type = MemoryDisk.self) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<D>.scratchBytes,
            alignment: 8
        )
    }

    private func withDisk(
        _ sectors: UInt64 = FailClosedTests.sectors,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk  = MemoryDisk(sectors: sectors)
        let space = scratch(MemoryDisk.self)
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }

    private func named(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }


    /// Puts `count` after-images into the open transaction, of blocks nothing
    /// else in the test touches.
    ///
    /// The point of the far end of the data region: staging is indifferent to
    /// what a block is for, so these fill the journal without also being the
    /// bitmap block or the table block the operation under test needs.
    @discardableResult
    private func stage(
        _ fs: inout FileSystem<MemoryDisk>,
        count: Int
    ) -> Bool {
        let payload = UnsafeMutableRawPointer.allocate(
            byteCount: Self.block, alignment: 8
        )
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x11, count: Self.block)

        for index in 0..<count {
            let target = fs.plan.dataStart + 1000 + UInt32(index)

            guard fs.stageStructuralBlock(
                target, from: UnsafeRawPointer(payload)
            ) == .ok else {
                Issue.record("image \(index) would not stage")
                return false
            }
        }

        return true
    }


    private func fixtureFile(
        _ fs: inout FileSystem<MemoryDisk>,
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

        let bytes   = Self.block * blocks
        let payload = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

        guard fs.write(
            object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(bytes)
        ).status == .ok else {
            Issue.record("the fixture file would not be written")
            return nil
        }

        return object
    }


    // MARK: - The sticky refusal

    @Test("finish(.ok) over a refused staging call aborts anyway")
    func okDoesNotOverruleARefusal() {
        withDisk { fs, _ in
            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x22, count: Self.block)

            #expect(fs.begin() == .ok)
            #expect(stage(&fs, count: FSJournal.capacity))

            // The seventeenth, refused at the door.
            #expect(fs.stageStructuralBlock(
                fs.plan.dataStart, from: UnsafeRawPointer(payload)
            ) == .tooManyChanges)

            #expect(fs.transactionRefusal == .tooManyChanges)

            // The whole point: the caller says the operation went fine, and it
            // is abandoned regardless, with the refusal reported.
            #expect(fs.finish(.ok) == .tooManyChanges)

            #expect(!fs.inTransaction)
            #expect(fs.journalIsEmpty)

            // And the next transaction is clean: the refusal belonged to the one
            // that was abandoned, not to the volume.
            #expect(fs.begin() == .ok)
            #expect(fs.transactionRefusal == nil)
            fs.abort()
        }
    }


    @Test("the refusal kept is the first one, not the last")
    func theFirstRefusalIsTheOneReported() {
        withDisk { fs, disk in
            #expect(fs.begin() == .ok)

            // A run below the data region is not a run this can give back, and
            // it is the one refusal that needs no broken device to provoke.
            #expect(fs.releaseRun(start: 0, count: 1) == .deviceFailed)
            #expect(fs.transactionRefusal == .deviceFailed)

            // A second, different refusal on top of it.
            #expect(stage(&fs, count: FSJournal.capacity))
            #expect(fs.setRange(
                start: fs.plan.dataStart, count: 1, used: true
            ) == .tooManyChanges)

            #expect(fs.transactionRefusal == .deviceFailed)
            #expect(fs.finish(.ok) == .deviceFailed)

            _ = disk
        }
    }


    @Test("a release the map cannot make is not reported as success")
    func aSwallowedReleaseIsGone() {
        withDisk { fs, disk in
            guard let file = fixtureFile(&fs, "kept.bin", blocks: 2) else { return }

            let before = fs.freeBlocks()

            #expect(fs.begin() == .ok)

            // Fifteen, so the record write below is the sixteenth and fits and
            // the bitmap write after it is the seventeenth and does not.
            #expect(stage(&fs, count: FSJournal.capacity - 1))

            let cut = fs.truncateStaged(file, to: 0)
            #expect(cut == .tooManyChanges)

            #expect(fs.finish(cut) == .tooManyChanges)

            // Nothing was freed and nothing was committed, which is the answer
            // the status now agrees with.
            #expect(fs.freeBlocks() == before)
            #expect(fs.object(file)?.blocks == 2)

            _ = disk
        }
    }


    @Test("compacting refuses rather than losing the new run's claim")
    func compactPropagates() {
        withDisk { fs, _ in
            guard let file = fixtureFile(&fs, "torn.bin", blocks: 1) else { return }

            // A second extent, so there is something to compact: one block that
            // does not carry on from the first.
            guard var record = fs.object(file) else { return }
            let gap = record.runs[0].start + record.runs[0].count + 4

            #expect(fs.begin() == .ok)
            #expect(fs.allocateAt(gap, count: 1) == .ok)

            let joined = record.append(start: gap, count: 1)
            #expect(joined)

            record.size = UInt64(Self.block) * 2
            #expect(fs.store(record, at: file) == .ok)
            #expect(fs.commit() == .ok)

            let before = fs.freeBlocks()

            #expect(fs.begin() == .ok)
            #expect(stage(&fs, count: FSJournal.capacity - 1))

            let packed = fs.compactStaged(file)
            #expect(packed != .ok)
            #expect(fs.finish(packed) != .ok)

            // The old runs are still the file's, and the map has not been left
            // holding a run nobody owns.
            #expect(fs.object(file)?.extents == 2)
            #expect(fs.freeBlocks() == before)
        }
    }


    // MARK: - The preflight

    @Test("a run that would want a seventeenth image is refused whole")
    func theRunIsRefusedBeforeTheFirstImage() {
        withDisk(Self.wideSectors) { fs, disk in

            // The whole point of the wide disk. Recorded rather than skipped, so
            // a build where the geometry changed says so instead of passing.
            #expect(fs.plan.bitmapBlocks >= 2, "one bitmap block cannot span a boundary")
            guard fs.plan.bitmapBlocks >= 2 else { return }

            let perBitmapBlock = UInt32(FileSystem<MemoryDisk>.blocksPerBitmapBlock)

            #expect(fs.begin() == .ok)

            // Fifteen, so one more image fits and two do not: without the
            // preflight the door would take the first and refuse the second.
            #expect(stage(&fs, count: FSJournal.capacity - 1))

            let writes = disk.writes
            let claimed = fs.setRange(start: perBitmapBlock - 4, count: 8, used: true)

            #expect(claimed == .tooManyChanges)

            // Nothing was written at all, which is what makes this a preflight
            // and not the door refusing one block late.
            #expect(disk.writes == writes)
            #expect(fs.transactionOverflows == 1)

            #expect(fs.finish(.ok) == .tooManyChanges)
        }
    }


    @Test("a run whose bitmap blocks are already staged still fits")
    func alreadyStagedBlocksAreFree() {
        withDisk { fs, _ in
            #expect(fs.begin() == .ok)

            // One bitmap block, staged sixteen times over. Coalescing makes it
            // one image, and the preflight has to count it the same way.
            for step in 0..<UInt32(FSJournal.capacity) {
                #expect(fs.setRange(
                    start: fs.plan.dataStart + step, count: 1, used: true
                ) == .ok, "claim \(step)")
            }

            #expect(fs.transactionOverflows == 0)
            #expect(fs.transactionRefusal == nil)
            #expect(fs.commit() == .ok)
        }
    }


    // MARK: - What the medium says afterwards

    @Test("an abandoned poisoned transaction changes nothing outside the journal")
    func nothingButTheJournalMoves() {
        let disk  = CrashDisk(sectors: Self.sectors)
        let space = scratch(CrashDisk.self)
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the fixture disk would not format")
            return
        }
        #expect(disk.flush() == .ok)

        let before = disk.snapshot()

        let payload = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x7E, count: Self.block)

        #expect(fs.begin() == .ok)

        for index in 0..<FSJournal.capacity {
            #expect(fs.stageStructuralBlock(
                fs.plan.dataStart + UInt32(index), from: UnsafeRawPointer(payload)
            ) == .ok)
        }

        #expect(fs.stageStructuralBlock(
            fs.plan.dataStart + UInt32(FSJournal.capacity), from: UnsafeRawPointer(payload)
        ) == .tooManyChanges)

        #expect(fs.finish(.ok) == .tooManyChanges)
        #expect(disk.flush() == .ok)

        let after = disk.snapshot()

        // The superblocks and the journal header included: an abandoned
        // transaction writes no header at all.
        let payloads = Int(FSLayout.journalStart) * Self.block
            ..< Int(FSLayout.reservedBlocks) * Self.block

        #expect(Array(after[..<payloads.lowerBound]) == Array(before[..<payloads.lowerBound]))
        #expect(Array(after[payloads.upperBound...]) == Array(before[payloads.upperBound...]))

        // And the disk mounts with an empty journal, so nothing is replayed.
        let again = CrashDisk(restarting: disk)
        let other = scratch(CrashDisk.self)
        defer { other.deallocate() }

        let attempt = FileSystem.mount(again, scratch: other)
        if case .ok = attempt.found {} else { Issue.record("mount: \(attempt.found)") }

        guard var mounted = attempt.disk else { return }
        #expect(mounted.begin() == .ok)
        mounted.abort()
    }


    // MARK: - Fault injection on every request

    /// Runs `operation` once for every point at which the device can begin
    /// refusing, and asks the *medium* whether the answer was true.
    ///
    /// The one direction that must hold everywhere: `ok` is only ever said about
    /// a change the disk has. The other direction is allowed to be untrue and has
    /// to be - a commit whose journal header is down is promised, so a refusal
    /// after it is a refusal for a change the next mount will finish.
    ///
    /// Asked after a fresh mount rather than of the file system that failed,
    /// because the mount is what replays that journal. Reading the live one would
    /// call a committed transaction missing.
    private func faults(
        _ what   : String,
        upTo limit: Int = 30,
        prepare  : (inout FileSystem<MemoryDisk>) -> Void = { _ in },
        operation: (inout FileSystem<MemoryDisk>) -> FSStatus,
        landed   : (inout FileSystem<MemoryDisk>) -> Bool
    ) {
        var done    = 0
        var refused = 0

        for stop in 1...limit {
            let disk  = MemoryDisk(sectors: Self.sectors)
            let space = scratch(MemoryDisk.self)
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("\(what): format")
                return
            }

            prepare(&fs)
            #expect(disk.flush() == .ok, "\(what) stop \(stop): the fixture would not settle")

            disk.failAfter(stop)
            let status = operation(&fs)
            disk.recover()

            let other = scratch(MemoryDisk.self)
            defer { other.deallocate() }

            let attempt = FileSystem.mount(disk, scratch: other)

            guard var again = attempt.disk else {
                Issue.record("\(what) stop \(stop): would not mount, \(attempt.found)")
                continue
            }

            // Whatever the journal was holding is finished or thrown away.
            #expect(again.begin() == .ok, "\(what) stop \(stop): the journal was left holding something")
            again.abort()

            if status == .ok {
                done += 1
                #expect(landed(&again), "\(what) stop \(stop): said ok for a change the disk has not got")

            } else {
                refused += 1
            }

            let findings = again.scan(.everything)
            #expect(findings.ownedButFree == 0, "\(what) stop \(stop): blocks owned and free")
            #expect(findings.claimedTwice == 0, "\(what) stop \(stop): blocks owned twice")
            #expect(findings.wrongQuota   == 0, "\(what) stop \(stop): room that does not add up")
            #expect(findings.strayNames   == 0, "\(what) stop \(stop): a name pointing at nothing")
            #expect(findings.impossible   == 0, "\(what) stop \(stop): a record that cannot be true")
        }

        #expect(done    > 0, "\(what): no fault point let the operation through")
        #expect(refused > 0, "\(what): no fault point stopped it")
    }


    private func lives(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString
    ) -> Bool {
        var found: UInt32? = nil
        named(name) { pointer, length in
            found = fs.lookup(pointer, length: length, in: FSLayout.rootObject).object
        }

        guard let found else { return false }
        return fs.object(found)?.kind != .free
    }


    @Test("a refused write is never reported as a write that happened")
    func createUnderFaults() {
        faults("create", operation: { fs in
            var status = FSStatus.notFound
            named("new.bin") { pointer, length in
                status = fs.create(
                    pointer, length: length, kind: .file, in: FSLayout.rootObject
                ).status
            }
            return status

        }, landed: { fs in self.lives(&fs, "new.bin") })
    }


    @Test("a refused remove is never reported as a remove that happened")
    func removeUnderFaults() {
        faults("remove", prepare: { fs in
            _ = self.fixtureFile(&fs, "gone.bin", blocks: 1)

        }, operation: { fs in
            var status = FSStatus.notFound
            self.named("gone.bin") { pointer, length in
                status = fs.remove(pointer, length: length, from: FSLayout.rootObject)
            }
            return status

        }, landed: { fs in !self.lives(&fs, "gone.bin") })
    }


    @Test("a refused truncate is never reported as a truncate that happened")
    func truncateUnderFaults() {
        var object: UInt32 = 0

        faults("truncate", prepare: { fs in
            object = self.fixtureFile(&fs, "long.bin", blocks: 3) ?? 0

        }, operation: { fs in
            fs.truncate(object, to: 0)

        }, landed: { fs in fs.object(object)?.blocks == 0 })
    }


    @Test("a refused grant of room is never reported as a grant that happened")
    func grantUnderFaults() {
        var child: UInt32 = 0

        faults("grantQuota", prepare: { fs in
            self.named("inner") { pointer, length in
                let made = fs.createContainer(
                    pointer, length: length, quota: 8, in: FSLayout.rootObject
                )
                if made.status == .ok { child = made.object }
            }

        }, operation: { fs in
            fs.grantQuota(4, from: FSLayout.rootObject, to: child)

        }, landed: { fs in fs.object(child)?.quota == 12 })
    }


    // MARK: - The bytes a failed write reports

    @Test("a write whose metadata never landed reports no bytes")
    func noBytesWithoutACommit() {
        let payload = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x3C, count: Self.block)

        var stopped = 0
        var wrote   = 0

        for stop in 1...40 {
            let disk  = MemoryDisk(sectors: Self.sectors)
            let space = scratch(MemoryDisk.self)
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format")
                return
            }

            var object: UInt32 = 0
            named("bytes.bin") { pointer, length in
                let made = fs.create(
                    pointer, length: length, kind: .file, in: FSLayout.rootObject
                )
                object = made.object
            }

            disk.failAfter(stop)
            let done = fs.write(
                object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(Self.block)
            )
            disk.recover()

            // A caller told "one block written" over a size that was never
            // published would carry on from an offset the file never reached.
            if done.status == .ok {
                wrote += 1
                #expect(done.bytes == UInt64(Self.block), "stop \(stop)")

            } else {
                stopped += 1
                #expect(done.bytes == 0, "stop \(stop): \(done.bytes) bytes for \(done.status)")
            }
        }

        #expect(wrote   > 0, "no fault point let the write through")
        #expect(stopped > 0, "no fault point stopped the write")
    }


    // MARK: - The rule, checked against the source

    /// Every structural mutation's `FSStatus` is either used or explicitly
    /// discarded, and the explicit discards are what this looks for.
    ///
    /// The compiler covers the rest: a non-`Void` result that is simply dropped
    /// is a warning, and this build has none. What it cannot see is `_ = `, which
    /// is how every one of the swallowed statuses this feature closed was
    /// written. So the ban is on the spelling, and it is checked against the
    /// files rather than argued about in a comment.
    @Test("no structural mutation in ReixFS drops its status with an underscore")
    func nothingIsDiscarded() {
        let here   = URL(fileURLWithPath: #filePath)
        let source = here
            .deletingLastPathComponent()    // FileSystemTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // the package
            .appendingPathComponent("Sources/ReixFS")

        let banned = [
            "store(", "setRange(", "setUsed(", "releaseRun(", "releaseObject(",
            "refund(", "charge(", "shrink(", "compact(", "stageStructuralBlock(",
            "writeDataBlock(", "writeRawBlock(", "zeroDataBlock(", "zeroRawBlock(",
            "link(", "unlink(", "grow(", "allocateAt(", "repair(",
            "commit(", "finish(", "publishSuperblock(", "emptyJournal(",
            "applyJournal(", "writeJournalHeader(", "barrier(",
            "forEachEntry(", "emptiness(", "lookup(", "depth(",
            "unmount(", "install(", "publishSuperblock(",
        ]

        // The file system server's own two-step unmount: marking the medium
        // clean is one act and letting go of the volume at the block server is
        // another, and the second one's status used to be discarded - so a client
        // told `ok` believed a disk nobody may touch was free.
        let server = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Userland/FileSystemServer")

        guard var files = try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil
        ) else {
            Issue.record("the ReixFS sources are not where this test looks: \(source.path)")
            return
        }

        files += (try? FileManager.default.contentsOfDirectory(
            at: server, includingPropertiesForKeys: nil
        )) ?? []

        var checked = 0

        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                Issue.record("\(file.lastPathComponent) would not read")
                continue
            }
            checked += 1

            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)

                guard let discard = code.range(of: "_ = ", options: .backwards) else {
                    continue
                }

                // The *discarded* call and not any call on the line. A status
                // handed to `answer` and then replied is used, and the `_ =` in
                // front of it belongs to the reply.
                let tail = code[discard.upperBound...]
                guard let open = tail.firstIndex(of: "(") else { continue }

                let head = String(tail[tail.startIndex...open])

                for call in banned where head.hasSuffix(call) {
                    Issue.record(
                        "\(file.lastPathComponent):\(number + 1) discards the status of \(call): \(code)"
                    )
                }
            }
        }

        #expect(checked >= 10, "only \(checked) source files were read")
    }
}
