//
//  CorruptRecordTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What the file system does when the disk says something impossible.
///
/// The reader used to clamp the extent count and believe everything else, so a
/// record whose runs pointed at block two was a record whose *file* read and
/// wrote the block bitmap. Nothing between the extent and the disk asked:
/// `readBlock` checks whether a block is on the device, and the bitmap is on the
/// device.
///
/// Every test here writes a real file system, damages one field of one record on
/// the disk, and then asks two things. Is the record served? And is anything
/// still written afterwards? The second matters as much as the first: a disk that
/// has contradicted itself once is a disk whose next write is the one that makes
/// the damage permanent.
///
/// There are two doors, and which one answers depends on when the damage
/// arrived. Damage that was already on the medium is met by the scan every mount
/// runs, so the volume is never served at all: `mount` answers `.corrupt` and
/// leaves the disk byte for byte as it found it. Damage that arrives under a
/// live mount is met by the decoder, which hands back nothing for the record and
/// holds the volume still. The tests below ask the first of a record damaged
/// while nothing was mounted and the second of one damaged while somebody was.
@Suite("A record that could not be true is not believed")
struct CorruptRecordTests {

    private static let sectors: UInt64 = 4096   // 2 MiB


    /// A mounted disk with one file on it, and where that file's record sits.
    private func withVictim(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk, UInt32, Int, FSLayout.Plan) -> Void
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

        let name = "victim.bin" as StaticString
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        guard made.status == .ok else {
            Issue.record("the fixture file would not be made")
            return
        }

        let payload = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x2B, count: 4096)

        guard fs.write(
            made.object, at: 0, from: UnsafeRawPointer(payload), count: 4096
        ).status == .ok else {
            Issue.record("the fixture file would not be filled")
            return
        }

        // Where that record sits, behind the file system's back.
        let plan   = fs.plan
        let where_ = Int(plan.tableStart) * Int(FSLayout.blockSize)
            + Int(made.object) * Int(FSLayout.objectSize)

        body(&fs, disk, made.object, where_, plan)
    }


    /// Damages one field of the victim's record with nothing mounted, and asks
    /// the door what it made of the disk.
    ///
    /// The mount is the assertion, which is why it lives in the fixture rather
    /// than in every test: a table that contradicts itself is found by the scan
    /// `mount` runs before it serves anything, so there is no file system to
    /// hand back. Both halves of the old question are still asked, of the volume
    /// instead of the record: not served, and not written to either.
    private func refusedAtTheDoor(
        _ damage: (MemoryDisk, Int, FSLayout.Plan) -> Void
    ) {
        withVictim { fs, disk, _, at, plan in
            #expect(fs.unmount() == .ok)

            damage(disk, at, plan)

            // A mount of its own, with its own scratch: the one above belongs to
            // a file system that has been unmounted.
            let scratch = UnsafeMutableRawPointer.allocate(
                byteCount: FileSystem<MemoryDisk>.scratchBytes,
                alignment: 8
            )
            defer { scratch.deallocate() }

            let before = disk.writes
            let opened = FileSystem.mount(disk, scratch: scratch)

            #expect(opened.disk == nil)
            #expect(isCorrupt(opened.found))
            #expect(
                disk.writes == before,
                "the disk was written to after being refused"
            )
        }
    }


    // MARK: - Runs that reach where they must not

    @Test("a run pointing into the file system's own blocks is not believed")
    func runBelowTheDataRegionIsRefused() {
        // The one that mattered. Block one is the bitmap on this layout, so the
        // old reader turned this record into a file whose bytes *were* the map
        // of which blocks are free.
        refusedAtTheDoor { disk, at, _ in
            disk.poke(UInt32(1), at: at + 64)          // runs[0].start
            disk.poke(UInt32(1), at: at + 68)          // runs[0].count
        }
    }


    @Test("a run reaching past the end of the disk is not believed")
    func runPastTheEndIsRefused() {
        refusedAtTheDoor { disk, at, plan in
            disk.poke(plan.totalBlocks - 1, at: at + 64)
            disk.poke(UInt32(8), at: at + 68)
        }
    }


    @Test("a run whose length wraps the address space is not believed")
    func wrappingRunIsRefused() {
        // The dangerous shape: added narrow, `start + count` comes back small
        // and passes every bound. Added wide, it does not.
        refusedAtTheDoor { disk, at, plan in
            disk.poke(plan.dataStart, at: at + 64)
            disk.poke(UInt32.max, at: at + 68)
        }
    }


    // MARK: - Records that disagree with themselves

    @Test("a run of no blocks is not believed")
    func emptyRunIsRefused() {
        refusedAtTheDoor { disk, at, _ in
            disk.poke(UInt32(0), at: at + 68)          // runs[0].count
        }
    }


    @Test("runs that do not add up to the block count are not believed")
    func blockCountMismatchIsRefused() {
        refusedAtTheDoor { disk, at, _ in
            disk.poke(UInt32(9), at: at + 4)           // blocks
        }
    }


    @Test("a record whose runs overlap each other is not believed")
    func overlappingRunsAreRefused() {
        refusedAtTheDoor { disk, at, plan in
            // Two runs over the same block, and a block count that agrees with
            // the sum so only the overlap gives it away.
            disk.poke(UInt8(2), at: at + 1)            // extents
            disk.poke(UInt32(2), at: at + 4)           // blocks
            disk.poke(plan.dataStart, at: at + 64)
            disk.poke(UInt32(1), at: at + 68)
            disk.poke(plan.dataStart, at: at + 72)
            disk.poke(UInt32(1), at: at + 76)
        }
    }


    @Test("more runs than a record has room for is not believed")
    func tooManyExtentsIsRefused() {
        refusedAtTheDoor { disk, at, _ in
            disk.poke(UInt8(200), at: at + 1)          // extents
        }
    }


    @Test("a size longer than the blocks to hold it is not believed")
    func oversizeIsRefused() {
        refusedAtTheDoor { disk, at, _ in
            disk.poke(UInt64(1 << 40), at: at + 8)     // size
        }
    }


    @Test("a container or folder number past the table is not believed")
    func wildParentIsRefused() {
        refusedAtTheDoor { disk, at, _ in
            disk.poke(UInt32(0xFFFF), at: at + 44)     // parent
        }
    }


    // MARK: - The same record, damaged under a live mount

    @Test("a record damaged while mounted is refused where it is read")
    func theReaderRefusesTheRecordItself() {
        // The other door. The volume is already open, so nothing gets to refuse
        // it at the door: what answers is the decoder, on the read.
        withVictim { fs, disk, object, at, _ in
            disk.poke(UInt32(1), at: at + 64)          // runs[0].start
            disk.poke(UInt32(1), at: at + 68)          // runs[0].count

            // The cache dropped so the next read goes to the medium, which is
            // where the damage is.
            fs.dropCache()

            // Not served. The record reads the same as nothing at that number,
            // which is what every caller already knows how to handle.
            #expect(fs.object(object) == nil)

            // And held still, from that moment. `writeBlock` is the one door
            // every change comes through, so one guard holds the whole volume.
            #expect(fs.corrupted)

            let before = disk.writes

            let name = "after.bin" as StaticString
            let made = fs.create(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                kind  : .file,
                in    : FSLayout.rootObject
            )

            #expect(made.status != .ok)
            #expect(
                disk.writes == before,
                "the disk was written to after being quarantined"
            )
        }
    }


    // MARK: - Two records claiming one block

    @Test("two records claiming one block is found, and stops the writing")
    func doubleClaimIsFound() {
        // What no repair can undo: the two owners are equally plausible from the
        // outside. So it is reported and the volume is held still, and nothing
        // pretends to pick a winner.
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        var made: [UInt32] = []
        for name in ["a.bin", "b.bin"] {
            let bytes = Array(name.utf8)
            let object = bytes.withUnsafeBytes { raw -> UInt32? in
                let result = fs.create(
                    raw.baseAddress!, length: bytes.count, kind: .file, in: FSLayout.rootObject
                )
                return result.status == .ok ? result.object : nil
            }
            guard let object else {
                Issue.record("a fixture file would not be made")
                return
            }

            let payload = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x11, count: 4096)

            #expect(fs.write(
                object, at: 0, from: UnsafeRawPointer(payload), count: 4096
            ).status == .ok)

            made.append(object)
        }

        guard let first = fs.object(made[0]), let second = fs.object(made[1]) else {
            Issue.record("the fixture records are not readable")
            return
        }
        #expect(first.runs[0].start != second.runs[0].start)

        // Point the second record's run at the first record's block. Both
        // records are perfectly well formed; it is the pair that is wrong.
        let plan = fs.plan
        let at = Int(plan.tableStart) * Int(FSLayout.blockSize)
            + Int(made[1]) * Int(FSLayout.objectSize)

        disk.poke(first.runs[0].start, at: at + 64)
        fs.dropCache()

        // Planted under the live mount and asked of it, because a pair like this
        // one on the medium is a disk `mount` refuses outright: that is what the
        // tests above assert, and it would leave nothing here to scrub.
        //
        // Both records pass on their own, so nothing is quarantined until the
        // scrub puts them side by side.
        #expect(fs.object(made[0]) != nil)
        #expect(fs.object(made[1]) != nil)
        #expect(!fs.corrupted)

        let findings = fs.putRight()

        #expect(findings.claimedTwice > 0)
        #expect(findings.damaged)
        #expect(fs.corrupted)
    }


    // MARK: - A name whose target does not agree

    @Test("a directory entry the target does not agree with resolves to nothing")
    func forgedEntryResolvesToNothing() {
        // The isolation half. Containment is a walk up the parent chain, so an
        // entry planted in a folder somebody holds used to hand back an object
        // that chain never passes through - reachable by name, outside by right.
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        // A container with a secret inside it, and a folder outside.
        let vault = "vault" as StaticString
        let room = fs.createContainer(
            UnsafeRawPointer(vault.utf8Start),
            length: vault.utf8CodeUnitCount,
            quota : 32,
            in    : FSLayout.rootObject
        )
        guard room.status == .ok else {
            Issue.record("the fixture container would not be made")
            return
        }

        let secret = "secret.bin" as StaticString
        let hidden = fs.create(
            UnsafeRawPointer(secret.utf8Start),
            length: secret.utf8CodeUnitCount,
            kind  : .file,
            in    : room.object
        )
        guard hidden.status == .ok else {
            Issue.record("the fixture secret would not be made")
            return
        }

        let outside = "outside" as StaticString
        let folder = fs.create(
            UnsafeRawPointer(outside.utf8Start),
            length: outside.utf8CodeUnitCount,
            kind  : .folder,
            in    : FSLayout.rootObject
        )
        guard folder.status == .ok else {
            Issue.record("the fixture folder would not be made")
            return
        }

        // A name in the outside folder pointing at the secret. Written the only
        // way the format allows a name to be written, so nothing about the entry
        // itself is malformed: it simply names something that does not agree.
        let planted = "loot" as StaticString
        let made = fs.create(
            UnsafeRawPointer(planted.utf8Start),
            length: planted.utf8CodeUnitCount,
            kind  : .file,
            in    : folder.object
        )
        guard made.status == .ok else {
            Issue.record("the fixture entry would not be made")
            return
        }

        // Repoint it, on the disk, at the secret in the other container.
        guard let host = fs.object(folder.object) else { return }
        let block = Int(host.runs[0].start) * Int(FSLayout.blockSize)

        var slot: Int? = nil
        for index in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
            let at = block + index * Int(FSLayout.entrySize)
            if disk.byte(at: at + 4) == UInt8(planted.utf8CodeUnitCount) { slot = at }
        }
        guard let slot else {
            Issue.record("the planted entry is not on the disk")
            return
        }

        disk.poke(hidden.object, at: slot)

        // And the name now resolves to nothing at all, because the secret says
        // it lives in the vault and this is not the vault.
        #expect(fs.lookup(
            UnsafeRawPointer(planted.utf8Start),
            length: planted.utf8CodeUnitCount,
            in    : folder.object
        ).object == nil)

        // While the same object is still perfectly reachable where it does live.
        #expect(fs.lookup(
            UnsafeRawPointer(secret.utf8Start),
            length: secret.utf8CodeUnitCount,
            in    : room.object
        ).object == hidden.object)
    }
}
