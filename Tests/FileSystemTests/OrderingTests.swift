//
//  OrderingTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// The one invariant this format has instead of a transaction.
///
/// > The map says a block is used for at least as long as any record points at
/// > it.
///
/// Every operation that gives blocks back used to give them back first and
/// write the shortened record second, so there was a window - one write wide,
/// and a power cut is a write wide - in which a live record named blocks the
/// map already called free. The next file to ask for space got them, and two
/// objects owning one block is not something a check can put right afterwards:
/// both owners are plausible.
///
/// So these tests do not check that operations succeed. They break the disk in
/// the middle, at every point it can be broken, and ask whether what is left
/// still adds up. `check` answers that exactly: `reclaimedTwice` counts blocks
/// an object owns that the map called free, and the whole of the ordering rule
/// is that this number can never be anything but zero.
///
/// Every one of those questions is asked of the medium and not of the file
/// system's memory of it, which is what `dropCache` below is for. The rule is a
/// statement about what reached the disk; a scan that could be answered out of
/// blocks held in hand would pass by agreeing with the code it is checking.
@Suite("Ordering, in place of a transaction")
struct OrderingTests {

    private static let sectors: UInt64 = 4096   // 2 MiB

    /// Far more steps than any of these operations takes. Past the end of one,
    /// the failure never fires and the iteration is just the success case again,
    /// which is worth asserting too.
    private static let steps = 30


    private func withDisk(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }


    /// A file of `blocks` blocks, named `name` in the root.
    @discardableResult
    private func file(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        blocks: Int
    ) -> UInt32? {

        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        guard made.status == .ok else {
            Issue.record("the fixture file would not be made")
            return nil
        }

        let bytes = Int(FSLayout.blockSize) * blocks
        let payload = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { payload.deallocate() }

        payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

        let written = fs.write(
            made.object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(bytes)
        )
        guard written.status == .ok else {
            Issue.record("the fixture file would not be filled")
            return nil
        }

        return made.object
    }


    /// Runs `work` with the disk refusing from its `nth` request onward, then
    /// answers how many blocks an object owns that the map calls free.
    ///
    /// Zero is the only acceptable answer, whatever the operation did.
    private func ownedButFree(
        _ fs: inout FileSystem<MemoryDisk>,
        _ disk: MemoryDisk,
        failingAt nth: Int,
        _ work: (inout FileSystem<MemoryDisk>) -> FSStatus
    ) -> (loose: UInt32, status: FSStatus) {

        disk.failAfter(nth)
        let status = work(&fs)
        disk.recover()

        fs.dropCache()

        return (fs.scan().ownedButFree, status)
    }


    // MARK: - Shrinking

    @Test("a cut that fails at any step never leaves a block owned and free")
    func shrinkIsOrdered() {
        var refusals = 0

        for step in 1...Self.steps {
            withDisk { fs, disk in
                guard let object = file(&fs, "big.bin", blocks: 6) else { return }

                let result = ownedButFree(&fs, disk, failingAt: step) {
                    $0.truncate(object, to: FSLayout.blockSize)
                }

                #expect(result.loose == 0, "step \(step) left a block owned and free")
                if result.status != .ok { refusals += 1 }
            }
        }

        // The loop has to have actually broken something, or it proves nothing.
        #expect(refusals > 0)
    }


    @Test("a cut that succeeds asks for the barrier it depends on")
    func shrinkAsksForTheBarrier() {
        withDisk { fs, disk in
            guard let object = file(&fs, "big.bin", blocks: 6) else { return }

            let before = disk.flushes
            #expect(fs.truncate(object, to: FSLayout.blockSize) == .ok)

            // Without this the ordering is a wish about a write cache.
            #expect(disk.flushes > before)

            fs.dropCache()
            #expect(fs.scan().ownedButFree == 0)
        }
    }


    // MARK: - Compacting

    /// The fixture needs three files, and it used to have two.
    ///
    /// With only two, growing the second one carried straight on from the blocks
    /// it already held, so it stayed in a single extent and `compact` returned at
    /// its first guard without touching the disk. This test compacted nothing for
    /// as long as it existed: the one refusal it counted came from the read
    /// *before* the work, and a cache in front of that read is what finally made
    /// it say so. The third file takes the blocks the growth wanted, and the
    /// assertion below is so it cannot go quiet that way again.
    @Test("putting a file back together fails without losing track of its blocks")
    func compactIsOrdered() {
        var refusals = 0

        for step in 1...Self.steps {
            withDisk { fs, disk in
                // Three in a row, and the middle one grown once the third has
                // taken the blocks it would otherwise have grown into.
                guard let first = file(&fs, "a.bin", blocks: 2),
                      let second = file(&fs, "b.bin", blocks: 2),
                      file(&fs, "c.bin", blocks: 2) != nil
                else { return }

                #expect(fs.truncate(first, to: 0) == .ok)

                let grown = UnsafeMutableRawPointer.allocate(
                    byteCount: Int(FSLayout.blockSize) * 3, alignment: 8
                )
                defer { grown.deallocate() }
                grown.initializeMemory(
                    as: UInt8.self, repeating: 0x33, count: Int(FSLayout.blockSize) * 3
                )

                _ = fs.write(
                    second,
                    at    : FSLayout.blockSize * 2,
                    from  : UnsafeRawPointer(grown),
                    count : FSLayout.blockSize * 3
                )

                #expect((fs.object(second)?.extents ?? 0) > 1, "nothing to compact")

                let result = ownedButFree(&fs, disk, failingAt: step) {
                    $0.compact(second)
                }

                #expect(result.loose == 0, "step \(step) left a block owned and free")
                if result.status != .ok { refusals += 1 }
            }
        }

        #expect(refusals > 0)
    }


    // MARK: - Removing

    @Test("removing a file fails without leaving its blocks owned and free")
    func removeIsOrdered() {
        var refusals = 0

        for step in 1...Self.steps {
            withDisk { fs, disk in
                guard file(&fs, "gone.bin", blocks: 4) != nil else { return }

                let name = "gone.bin" as StaticString

                let result = ownedButFree(&fs, disk, failingAt: step) {
                    $0.remove(
                        UnsafeRawPointer(name.utf8Start),
                        length: name.utf8CodeUnitCount,
                        from  : FSLayout.rootObject
                    )
                }

                #expect(result.loose == 0, "step \(step) left a block owned and free")
                if result.status != .ok { refusals += 1 }
            }
        }

        #expect(refusals > 0)
    }


    @Test("a removal that half happened leaves space lost, never handed out twice")
    func removeLeavesALeakAtWorst() {
        // Says out loud which of the two residues this format accepts. Blocks
        // marked used that nobody owns are reclaimable and `check` reclaims
        // them; blocks owned that the map calls free are not, and cannot happen.
        withDisk { fs, disk in
            guard file(&fs, "gone.bin", blocks: 4) != nil else { return }

            let name = "gone.bin" as StaticString

            disk.failAfter(3)
            _ = fs.remove(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                from  : FSLayout.rootObject
            )
            disk.recover()
            fs.dropCache()

            let findings = fs.check()
            #expect(findings.ownedButFree == 0)
        }
    }


    // MARK: - What is held in hand

    @Test("a block the disk tore in half is not remembered as though it landed")
    func aTornWriteIsNotRemembered() {
        // The one thing keeping metadata blocks in hand can get wrong that no
        // ordering test above would notice. A refused write that changed nothing
        // leaves the slot right by accident; a refused write that landed half a
        // block leaves it wrong, and every question asked afterwards is answered
        // out of it.
        withDisk { fs, disk in
            guard let object = file(&fs, "torn.bin", blocks: 1),
                  let before = fs.object(object)
            else { return }

            var longer = before
            longer.size = 1234

            disk.tearsOneWrite = true
            #expect(fs.store(longer, at: object) != .ok)

            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(object) * Int(FSLayout.objectSize)

            var onDisk = UInt64(0)
            for byte in 0..<8 {
                onDisk |= UInt64(disk.byte(at: at + 8 + byte)) << (8 * byte)
            }

            // The tear really did change the medium, or there is nothing here to
            // be wrong about.
            #expect(onDisk != before.size)

            guard let after = fs.object(object) else {
                Issue.record("the torn record became unreadable, which it does not")
                return
            }

            #expect(after.size == onDisk)
        }
    }


    @Test("a write the disk refused leaves nothing of itself behind")
    func aRefusedWriteIsNotRemembered() {
        // The other direction, and the one a cache gets wrong by being eager: a
        // block is only worth keeping once the device has said it took it.
        // Keeping what was handed down regardless makes every later read answer
        // out of a write that never happened.
        withDisk { fs, disk in
            guard let object = file(&fs, "kept.bin", blocks: 1),
                  let before = fs.object(object)
            else { return }

            var longer = before
            longer.size = 4321

            disk.failAfter(0)
            #expect(fs.store(longer, at: object) != .ok)
            disk.recover()

            guard let after = fs.object(object) else {
                Issue.record("the record went missing, and the disk was not written")
                return
            }

            #expect(after.size == before.size)
        }
    }


    // MARK: - Moving

    @Test("moving a name between folders never leaves it reachable from neither")
    func relocateKeepsItReachable() {
        for step in 1...12 {
            withDisk { fs, disk in
                let folder = "sub" as StaticString
                let made = fs.create(
                    UnsafeRawPointer(folder.utf8Start),
                    length: folder.utf8CodeUnitCount,
                    kind  : .folder,
                    in    : FSLayout.rootObject
                )
                guard made.status == .ok else { return }

                guard file(&fs, "doc.txt", blocks: 1) != nil else { return }

                let from = "doc.txt" as StaticString
                let to   = "doc.txt" as StaticString

                disk.failAfter(step)
                _ = fs.relocate(
                    UnsafeRawPointer(from.utf8Start),
                    length: from.utf8CodeUnitCount,
                    from  : FSLayout.rootObject,
                    to    : made.object,
                    as    : UnsafeRawPointer(to.utf8Start),
                    length: to.utf8CodeUnitCount
                )
                disk.recover()
                fs.dropCache()

                // Reachable from somewhere: the old name, the new one, or both.
                // Never from neither, which is what unlinking first would risk.
                let old = fs.lookup(
                    UnsafeRawPointer(from.utf8Start),
                    length: from.utf8CodeUnitCount,
                    in    : FSLayout.rootObject
                )
                let new = fs.lookup(
                    UnsafeRawPointer(to.utf8Start),
                    length: to.utf8CodeUnitCount,
                    in    : made.object
                )

                #expect(old != nil || new != nil, "step \(step) lost the file entirely")
                #expect(fs.scan().ownedButFree == 0)
            }
        }
    }


    @Test("a moved file claims the folder it is reachable from")
    func relocateKeepsParentAgreeing() {
        // The window the old order had: unlinked from the source and not yet
        // reparented, so the object was reachable by name from the target and
        // still claimed to live in the source. Containment is a walk up the
        // parent chain, so that object was findable and refused at the same
        // time.
        for step in 1...12 {
            withDisk { fs, disk in
                let folder = "sub" as StaticString
                let made = fs.create(
                    UnsafeRawPointer(folder.utf8Start),
                    length: folder.utf8CodeUnitCount,
                    kind  : .folder,
                    in    : FSLayout.rootObject
                )
                guard made.status == .ok, let object = file(&fs, "doc.txt", blocks: 1)
                else { return }

                let name = "doc.txt" as StaticString

                disk.failAfter(step)
                _ = fs.relocate(
                    UnsafeRawPointer(name.utf8Start),
                    length: name.utf8CodeUnitCount,
                    from  : FSLayout.rootObject,
                    to    : made.object,
                    as    : UnsafeRawPointer(name.utf8Start),
                    length: name.utf8CodeUnitCount
                )
                disk.recover()
                fs.dropCache()

                guard let record = fs.object(object) else {
                    Issue.record("step \(step) lost the record")
                    return
                }

                // Whichever folder it says it is in, that folder names it.
                let named = fs.lookup(
                    UnsafeRawPointer(name.utf8Start),
                    length: name.utf8CodeUnitCount,
                    in    : record.parent
                )

                #expect(named == object, "step \(step): the file is not in the folder it claims")
            }
        }
    }
}

/// What a device says a completed write has achieved, and what the file system
/// does about it.
///
/// The three words are not synonyms and the whole ordering rule rests on which
/// one a disk means: a write that has *completed* has been taken, a write that
/// is *ordered* cannot reach the medium after a later one, and a write that is
/// *durable* survives the power going. A disk with a write cache gives the first
/// and needs a flush for the other two; a disk without one gives all three at
/// once, and asking it for a barrier is a round trip for nothing.
@Suite("Completed, ordered and durable are three things")
struct DurabilityTests {

    private static let sectors: UInt64 = 4096


    private func withDisk(
        _ durability: BlockDurability,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)
        disk.durability = durability

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }


    private func file(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        blocks: Int
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        guard made.status == .ok else { return nil }

        let bytes = Int(FSLayout.blockSize) * blocks
        let payload = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

        guard fs.write(
            made.object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(bytes)
        ).status == .ok else { return nil }

        return made.object
    }


    @Test("a disk with a cache is asked for the barrier it needs")
    func cachedDiskIsFlushed() {
        withDisk(.onFlush) { fs, disk in
            guard let object = file(&fs, "big.bin", blocks: 6) else { return }

            let before = disk.flushes
            #expect(fs.truncate(object, to: FSLayout.blockSize) == .ok)
            #expect(disk.flushes > before)
        }
    }


    @Test("a disk without one is not asked, because the answer is already yes")
    func uncachedDiskIsNotFlushed() {
        // The declaration earning its keep. Without it every barrier on such a
        // disk is a round trip that changes nothing - and through a block client
        // that is a round trip across an IPC.
        withDisk(.onCompletion) { fs, disk in
            guard let object = file(&fs, "big.bin", blocks: 6) else { return }

            let before = disk.flushes
            #expect(fs.truncate(object, to: FSLayout.blockSize) == .ok)
            #expect(disk.flushes == before)
        }
    }


    @Test("skipping the flush does not skip the ordering")
    func uncachedDiskStillOrders() {
        // The thing that must not be traded away: the barrier is cheaper on such
        // a disk, not absent. Blocks are still released only after the record
        // that stopped naming them is written, so the invariant holds either way.
        for durability in [BlockDurability.onFlush, .onCompletion] {
            withDisk(durability) { fs, disk in
                guard let object = file(&fs, "big.bin", blocks: 6) else { return }

                disk.failAfter(4)
                _ = fs.truncate(object, to: FSLayout.blockSize)
                disk.recover()
                fs.dropCache()

                #expect(fs.scan().ownedButFree == 0)
            }
        }
    }


    @Test("what a device says about itself survives the trip to a client")
    func durabilityCrossesTheWire() {
        // It travels in the top bit of the sector-size word, because the four
        // words of a geometry answer were already spoken for and a sector size
        // is never that big.
        for durability in [BlockDurability.onFlush, .onCompletion] {
            let message = BlockOperation.geometry(
                sectorSize : 512,
                sectorCount: 32768,
                durability : durability
            )

            let device = BlockOperation.device(of: message)

            #expect(device.sectorSize == 512)
            #expect(device.sectorCount == 32768)
            #expect(device.durability == durability)
        }

        // And a large but real sector size still comes back whole.
        let big = BlockOperation.device(of: BlockOperation.geometry(
            sectorSize : 4096,
            sectorCount: 1,
            durability : .onFlush
        ))

        #expect(big.sectorSize == 4096)
        #expect(big.durability == .onFlush)
    }
}
