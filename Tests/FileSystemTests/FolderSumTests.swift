//
//  FolderSumTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 01/11/2026.
//

import Testing
@testable import ReixFS
import ReixABI

/// A folder block is checked against its checksum in the sum region, as a
/// file's block is, and refused the way a table block is.
///
/// Each entry has a check over its own bytes, and that catches an entry that
/// rotted. It cannot catch a whole block that is not the one last written: an
/// older version written back, or another folder's block that landed here, is
/// made of entries that each add up. The block's checksum moves with every
/// staged image of it, in the same transaction, so nothing but this file
/// system's own writes can make the two agree.
@Suite("A folder block is the one last written", .serialized)
struct FolderSumTests {

    /// 16 MiB, the Makefile's image.
    private static let sectors: UInt64 = 32768

    private static let block = Int(FSLayout.blockSize)


    /// The three ways a folder block stops being the one last written.
    private enum Damage: CaseIterable {
        case rot, stale, misdirected
    }


    // MARK: - Refused on read

    @Test("a folder block that is not the one last written is refused at its first read")
    func refusedOnRead() {
        for damage in Damage.allCases {
            withDamagedFolder(damage) { fs, disk, folder in
                let writes = disk.writes

                #expect(lookup(&fs, "a.txt", in: folder).refusal == .quarantined, "\(damage)")
                #expect(fs.corrupted, "\(damage)")

                // Held for good: the listing and every write after are refused.
                let room = UnsafeMutableRawPointer.allocate(byteCount: 8 * FSListEntry.width, alignment: 8)
                defer { room.deallocate() }
                #expect(fs.entries(from: 0, in: folder, into: room, capacity: 8).status == .quarantined)
                #expect(create(&fs, "c.txt", in: folder) == .quarantined, "\(damage)")
                #expect(disk.writes == writes, "\(damage)")
            }
        }
    }


    // MARK: - Refused by a mount that walks the folders

    @Test("a dirty mount refuses it, and writes nothing")
    func refusedByDirtyMount() {
        for damage in Damage.allCases {
            withDamagedFolder(damage) { _, disk, _ in
                let writes = disk.writes

                remount(disk) { again, found in
                    #expect(again == nil, "\(damage)")
                    #expect(isCorrupt(found), "\(damage): \(found)")
                }
                #expect(disk.writes == writes, "\(damage)")
            }
        }
    }


    @Test("a clean mount without a seal refuses it; one with a seal refuses its first read")
    func refusedByCleanMount() {
        for damage in Damage.allCases {
            for sealed in [false, true] {
                withDamagedFolder(damage, unmounted: true) { _, disk, folder in
                    if !sealed { disk.unseal(plan(disk)) }

                    remount(disk) { again, found in
                        guard sealed else {
                            #expect(again == nil, "\(damage)")
                            #expect(isCorrupt(found), "\(damage): \(found)")
                            return
                        }

                        // The seal speaks for the table and the sum region, and a
                        // clean mount reads no folder at all.
                        guard var again else { Issue.record("\(damage): \(found)"); return }
                        #expect(lookup(&again, "a.txt", in: folder).refusal == .quarantined)
                        #expect(again.corrupted, "\(damage)")
                    }
                }
            }
        }
    }


    // MARK: - Refused by a scrub, and never repaired

    @Test("a scrub stops at it and holds the volume, and a repair writes nothing")
    func refusedByScrub() {
        for damage in Damage.allCases {
            for depth in [FileSystem<MemoryDisk>.Scrub.everything, .data] {
                withDamagedFolder(damage) { fs, disk, _ in
                    let writes   = disk.writes
                    let findings = fs.scan(depth)

                    #expect(!findings.complete, "\(damage) \(depth)")
                    #expect(!findings.safeToServe, "\(damage) \(depth)")
                    #expect(fs.corrupted, "\(damage) \(depth)")
                    #expect(disk.writes == writes, "\(damage) \(depth)")
                }
            }

            withDamagedFolder(damage) { fs, disk, _ in
                let writes  = disk.writes
                let mending = fs.putRight()

                #expect(!mending.complete, "\(damage)")
                #expect(!mending.safeToServe, "\(damage)")
                #expect(!mending.mapMended && mending.roomsMended == 0, "\(damage)")
                #expect(fs.corrupted, "\(damage)")
                #expect(disk.writes == writes, "\(damage)")
            }
        }
    }


    @Test("a table block changed the same way is held the same way")
    func tableIsHeldAlike() {
        withFileSystem { fs, disk in
            guard make(&fs, "a.txt") != nil else { return }

            let at = Int(fs.plan.tableStart) * Self.block + 60
            disk.poke(disk.byte(at: at) ^ 0x5A, at: at)
            fs.dropCache()

            let writes   = disk.writes
            let findings = fs.scan(.everything)

            #expect(!findings.complete && !findings.safeToServe)
            #expect(fs.corrupted)
            #expect(disk.writes == writes)
        }
    }


    // MARK: - Kept true by every write

    @Test("every change to a folder moves its block's checksum with it")
    func everyChangeKeepsItTrue() {
        withFileSystem { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder) else { return }

            // Past one block of entries, so the folder grows by a fresh block.
            let perBlock = Int(FSLayout.blockSize / FSLayout.entrySize)
            for index in 0...perBlock {
                #expect(create(&fs, "n\(index)", in: folder) == .ok, "create \(index)")
            }
            #expect(fs.object(folder)?.blocks == 2)

            for index in stride(from: 0, through: perBlock, by: 3) {
                #expect(remove(&fs, "n\(index)", from: folder) == .ok, "remove \(index)")
            }

            fs.dropCache()
            let findings = fs.scan(.data)
            #expect(findings.complete && findings.safeToServe)
            #expect(findings.damagedData == 0)

            // And as the next mount finds it, dirty, so every folder is walked.
            remount(disk) { again, found in
                guard var again else { Issue.record("\(found)"); return }
                #expect(again.wasDirty)
                #expect(lookup(&again, "n1", in: folder).object != nil)
                #expect(!again.corrupted)
            }
        }
    }


    @Test("a create and a remove each stage one sum block more")
    func costOfChecking() {
        // Writes, barriers and reads from a cold cache. Before folder blocks had
        // checksums these were 7, 4, 3 and 9, 4, 5; the root adds two writes.
        withFileSystem { fs, disk in
            guard make(&fs, "first.bin") != nil else { return }
            fs.dropCache()

            let before = (disk.writes, disk.flushes, disk.reads)
            #expect(create(&fs, "second.bin", in: FSLayout.rootObject) == .ok)
            let made = (disk.writes - before.0, disk.flushes - before.1, disk.reads - before.2)
            #expect(made == (11, 4, 4), "\(made)")
        }

        // A file with a block of data, whose sum block is a different one.
        withFileSystem { fs, disk in
            guard let file = make(&fs, "first.bin") else { return }
            let bytes = [UInt8](repeating: 0x5C, count: 100)
            let wrote = bytes.withUnsafeBytes { raw in
                fs.write(file, at: 0, from: raw.baseAddress!, count: UInt64(bytes.count))
            }
            #expect(wrote.status == .ok)
            fs.dropCache()

            let before = (disk.writes, disk.flushes, disk.reads)
            #expect(remove(&fs, "first.bin", from: FSLayout.rootObject) == .ok)
            let gone = (disk.writes - before.0, disk.flushes - before.1, disk.reads - before.2)
            #expect(gone == (13, 4, 6), "\(gone)")
        }
    }


    // MARK: - Helpers

    /// A disk with a folder holding `a.txt` and `b.txt`, whose block has then
    /// been damaged behind the file system's back. Left mounted and dirty, or
    /// unmounted and sealed.
    private func withDamagedFolder(
        _ damage   : Damage,
        unmounted  : Bool = false,
        _ body     : (inout FileSystem<MemoryDisk>, MemoryDisk, UInt32) -> Void
    ) {
        withFileSystem { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder),
                  let other  = make(&fs, "more", kind: .folder),
                  make(&fs, "a.txt", in: folder) != nil,
                  make(&fs, "x.txt", in: other) != nil
            else { return }

            let home  = folderBlock(&fs, folder)
            let older = disk.block(home)

            guard make(&fs, "b.txt", in: folder) != nil else { return }

            if unmounted {
                #expect(fs.unmount() == .ok)
                #expect(fs.namedSeal != 0)
            }

            switch damage {
                case .rot:
                    // A byte of a free slot. The entry rule would catch this one
                    // too, on a walk that reaches it.
                    let at = Int(home) * Self.block + Self.block - 1
                    disk.poke(disk.byte(at: at) ^ 0x01, at: at)

                case .stale:
                    // The write that added `b.txt` was acknowledged and lost.
                    disk.put(older, block: home)

                case .misdirected:
                    // The other folder's block, landed here.
                    disk.put(disk.block(folderBlock(&fs, other)), block: home)
            }

            fs.dropCache()
            body(&fs, disk, folder)
        }
    }

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

    private func plan(_ disk: MemoryDisk) -> FSLayout.Plan {
        FSLayout.Plan(sectorCount: disk.sectorCount, sectorSize: disk.sectorSize)!
    }

    private func folderBlock(_ fs: inout FileSystem<MemoryDisk>, _ folder: UInt32) -> UInt32 {
        fs.object(folder)?.runs[0].start ?? 0
    }

    private func make(
        _  fs    : inout FileSystem<MemoryDisk>,
        _  name  : String,
           kind  : FSKind = .file,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        let bytes = Array(name.utf8)
        let made  = bytes.withUnsafeBytes { raw in
            fs.create(raw.baseAddress!, length: bytes.count, kind: kind, in: folder)
        }
        guard made.status == .ok else { Issue.record("create \(name): \(made.status)"); return nil }
        return made.object
    }

    private func create(_ fs: inout FileSystem<MemoryDisk>, _ name: String, in folder: UInt32) -> FSStatus {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBytes { raw in
            fs.create(raw.baseAddress!, length: bytes.count, kind: .file, in: folder).status
        }
    }

    private func remove(_ fs: inout FileSystem<MemoryDisk>, _ name: String, from folder: UInt32) -> FSStatus {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBytes { raw in
            fs.remove(raw.baseAddress!, length: bytes.count, from: folder)
        }
    }

    private func lookup(_ fs: inout FileSystem<MemoryDisk>, _ name: String, in folder: UInt32) -> FSFound {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBytes { raw in
            fs.lookup(raw.baseAddress!, length: bytes.count, in: folder)
        }
    }
}
